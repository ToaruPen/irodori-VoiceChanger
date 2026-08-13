import Foundation
import IrodoriVoiceChangerCore
import IrodoriVoiceChangerMacOS

enum CLIApplication {
    static func run(arguments: [String]) async -> Int32 {
        do {
            let command = try CLIParser.parse(arguments)
            return try await execute(command)
        } catch is CLIUsageError {
            writeError(usage)
            return CLIUsageError.exitCode
        } catch {
            writeError("operation_failed")
            return 1
        }
    }

    private static func execute(_ command: CLICommand) async throws -> Int32 {
        switch command {
        case .help:
            print(usage)
            return 0
        case .configInit(let path):
            try initializeConfiguration(path: path)
            print("configuration_created")
            return 0
        case .configValidate(let path):
            _ = try loadConfiguration(path: path)
            print("configuration_valid")
            return 0
        case .devices:
            try listDevices()
            return 0
        case .doctor(let path, let synthesize):
            let report = await runDoctor(path: path, synthesize: synthesize)
            printDoctor(report)
            return report.exitCode
        case .run(
            let path,
            let showTranscript,
            let shadowSynthesizePrefix,
            let endpointShadowMilliseconds,
            let shadowSmartTurn
        ):
            try await runLive(
                path: path,
                options: LiveOptions(
                    showTranscript: showTranscript,
                    shadowSynthesizePrefix: shadowSynthesizePrefix,
                    endpointShadowMilliseconds: endpointShadowMilliseconds,
                    shadowSmartTurn: shadowSmartTurn
                )
            )
            return 0
        case .replay(
            let input,
            let path,
            let synthesize,
            let liveOutput,
            let shadowSynthesizePrefix,
            let endpointShadowMilliseconds,
            let earlyFinalizeShadowMilliseconds,
            let smartTurnShadow
        ):
            try await runReplay(
                path: path,
                options: ReplayOptions(
                    input: input,
                    synthesize: synthesize,
                    liveOutput: liveOutput,
                    shadowSynthesizePrefix: shadowSynthesizePrefix,
                    endpointShadowMilliseconds: endpointShadowMilliseconds,
                    earlyFinalizeShadowMilliseconds: earlyFinalizeShadowMilliseconds,
                    smartTurnShadow: smartTurnShadow
                )
            )
            return 0
        case .report(let session, let path, let json):
            try printTelemetryReport(session: session, path: path, json: json)
            return 0
        }
    }

    private static func listDevices() throws {
        let devices = try AudioDeviceCatalog.current().outputs
        if devices.isEmpty {
            print("no_output_devices")
            return
        }
        for device in devices.sorted(by: {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }) {
            print("\(device.uid)\t\(device.name)\tchannels=\(device.outputChannelCount)")
        }
    }

    static func runReplay(
        path: String?,
        options: ReplayOptions
    ) async throws {
        guard !options.liveOutput || options.synthesize else { throw CLIUsageError() }
        let configuration = try await loadRuntimeConfiguration(path: path)
        try validateShadowSynthesis(
            enabled: options.shadowSynthesizePrefix,
            policy: configuration.speech.commitPolicy
        )
        let recorder = telemetryRecorder(configuration)
        let clock = SystemMonotonicClock()
        let sessionID = UUID()
        await recordSession(.sessionStarted, sessionID: sessionID, recorder: recorder, clock: clock)
        do {
            try await performReplay(
                options: options,
                configuration: configuration,
                recorder: recorder,
                clock: clock,
                sessionID: sessionID
            )
        } catch {
            let staged = error as? StagedRuntimeError
            await recordFailure(
                stage: staged?.stage ?? .lifecycle,
                code: staged?.code ?? stableCode(for: error),
                sessionID: sessionID,
                recorder: recorder,
                clock: clock
            )
            await recordSession(
                .sessionStopped, sessionID: sessionID, recorder: recorder, clock: clock)
            throw error
        }
        await recordSession(.sessionStopped, sessionID: sessionID, recorder: recorder, clock: clock)
        print("replay_complete session=\(sessionID.uuidString.lowercased())")
    }

    static func prepareSynthesizer(
        _ configuration: AppConfiguration
    ) async throws -> ConfiguredIrodoriSynthesizer {
        let client = IrodoriClient(baseURL: configuration.irodori.baseURL)
        _ = try await client.health()
        let voice = try await client.prepareVoice(configuredVoiceID: configuration.irodori.voiceID)
        return ConfiguredIrodoriSynthesizer(
            client: client,
            voice: voice,
            profile: synthesisProfile(configuration),
            maximumBytes: configuration.audio.maximumWAVBytes,
            maximumDurationSeconds: configuration.audio.maximumClipSeconds
        )
    }

    static func synthesisProfile(_ configuration: AppConfiguration) -> SynthesisProfile {
        SynthesisProfile(
            numSteps: configuration.irodori.numSteps,
            schedule: configuration.irodori.schedule,
            style: configuration.irodori.style,
            swayCoefficient: configuration.irodori.swayCoefficient
        )
    }

    static func telemetryRecorder(
        _ configuration: AppConfiguration
    ) -> SessionTelemetryRecorder {
        SessionTelemetryRecorder(
            base: JSONLTelemetryRecorder(
                directory: URL(filePath: expand(configuration.telemetry.directory)),
                maximumFileBytes: configuration.telemetry.maximumFileBytes,
                retainedFileCount: configuration.telemetry.retainedFileCount
            ),
            onFirstUnavailable: {
                FileHandle.standardError.write(Data("telemetry_unavailable\n".utf8))
            }
        )
    }

    static func shadowMonitor(
        _ policy: CommitPolicyConfiguration,
        _ sessionID: UUID,
        _ recorder: any TelemetryRecording,
        _ clock: any MonotonicClock,
        candidateHandler: (any StablePrefixCandidateHandling)? = nil
    ) -> StablePrefixShadowMonitor? {
        guard policy.mode == .stablePrefix else { return nil }
        return StablePrefixShadowMonitor(
            sessionID: sessionID,
            minimumObservations: policy.minimumObservations,
            minimumStableMilliseconds: policy.minimumStableMilliseconds,
            telemetry: recorder,
            clock: clock,
            candidateHandler: candidateHandler
        )
    }

    static func endpointShadowQueue(
        _ silenceMilliseconds: Int?,
        _ sessionID: UUID,
        _ recorder: any TelemetryRecording,
        _ clock: any MonotonicClock,
        candidateHandler: (any EndpointCandidateHandling)? = nil
    ) -> EndpointShadowQueue? {
        guard let silenceMilliseconds else { return nil }
        return EndpointShadowQueue(
            monitor: EndpointShadowMonitor(
                sessionID: sessionID,
                silenceMilliseconds: silenceMilliseconds,
                telemetry: recorder,
                candidateHandler: candidateHandler
            ),
            clock: clock
        )
    }

    static func endpointActivityObserver(
        _ queue: EndpointShadowQueue?
    ) -> (@Sendable (AudioActivitySample) -> Void)? {
        guard let queue else { return nil }
        return { sample in
            queue.observeAudio(
                EndpointAudioFrame(
                    isSpeech: sample.isSpeech,
                    durationMilliseconds: sample.durationMilliseconds,
                    sampleRate: sample.sampleRate,
                    samples: sample.samples
                )
            )
        }
    }

    static func validateShadowSynthesis(
        enabled: Bool,
        policy: CommitPolicyConfiguration
    ) throws {
        guard !enabled || policy.mode == .stablePrefix else { throw CLIUsageError() }
    }

    static func defaultTelemetryRecorder() -> SessionTelemetryRecorder {
        let directory = configurationURL(nil).deletingLastPathComponent()
            .appending(path: "telemetry", directoryHint: .isDirectory)
        return SessionTelemetryRecorder(
            base: JSONLTelemetryRecorder(
                directory: directory,
                maximumFileBytes: 5 * 1_024 * 1_024,
                retainedFileCount: 3
            ),
            onFirstUnavailable: {
                FileHandle.standardError.write(Data("telemetry_unavailable\n".utf8))
            }
        )
    }

    static func recordSession(
        _ name: TelemetryEventName,
        sessionID: UUID,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock
    ) async {
        _ = await recorder.record(
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: nil,
                timestampNanoseconds: clock.nowNanoseconds(),
                name: name,
                stage: .lifecycle
            ))
    }

    static func recordSpeechOnly(
        _ event: SpeechEvent,
        sessionID: UUID,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock
    ) async {
        let mapped: SpeechTelemetryMapping
        switch event {
        case .speechStarted(let id):
            mapped = .init(name: .speechStarted, utteranceID: id, revisionCount: nil)
        case .speechEnded(let id):
            mapped = .init(name: .speechEnded, utteranceID: id, revisionCount: nil)
        case .partial(let id, _, let revisions):
            mapped = .init(name: .asrPartial, utteranceID: id, revisionCount: revisions)
        case .final(let id, _, let revisions):
            mapped = .init(name: .asrFinal, utteranceID: id, revisionCount: revisions)
        case .timing(let id, let kind, _):
            let name: TelemetryEventName =
                switch kind {
                case .partial: .asrPartialTiming
                case .final: .asrFinalTiming
                case .speechEnd: .speechEndTiming
                }
            mapped = .init(
                name: name,
                utteranceID: id,
                revisionCount: nil
            )
        }
        let sourceLatency: Double?
        if case .timing(_, _, let deliveryMilliseconds) = event {
            sourceLatency = deliveryMilliseconds
        } else {
            sourceLatency = nil
        }
        _ = await recorder.record(
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: mapped.utteranceID,
                timestampNanoseconds: clock.nowNanoseconds(),
                name: mapped.name,
                stage: .speech,
                metrics: .init(
                    partialRevisionCount: mapped.revisionCount,
                    sourceLatencyMilliseconds: sourceLatency
                )
            ))
    }

    static func recordPreflight(
        stage: PipelineStage,
        since start: UInt64,
        sessionID: UUID,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock
    ) async {
        let now = clock.nowNanoseconds()
        _ = await recorder.record(
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: nil,
                timestampNanoseconds: now,
                name: .preflightCompleted,
                stage: stage,
                metrics: .init(durationMilliseconds: Double(now - start) / 1_000_000)
            ))
    }

    static func recordFailure(
        stage: PipelineStage,
        code: StableErrorCode,
        sessionID: UUID,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock
    ) async {
        _ = await recorder.record(
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: nil,
                timestampNanoseconds: clock.nowNanoseconds(),
                name: .operationFailed,
                stage: stage,
                errorCode: code
            ))
    }

    private static func printDoctor(_ report: DoctorReport) {
        for check in report.checks {
            let error = check.errorCode.map { " error=\($0.rawValue)" } ?? ""
            print("\(check.code.rawValue)\t\(check.status.rawValue)\(error)")
        }
    }

    static func stableCode(for error: Error) -> StableErrorCode {
        if let pipelineError = error as? PipelineOperationError {
            return pipelineError.code
        }
        if let clientError = error as? IrodoriClientError {
            return clientError.stableCode
        }
        if error is AppleSpeechSessionError {
            return .speechUnavailable
        }
        if error is CLIExecutionError {
            return .permissionDenied
        }
        return .invalidResponse
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static let usage = """
        Usage: irodori-voicechanger COMMAND
          config init [--path PATH]
          config validate [--path PATH]
          doctor [--path PATH] [--synthesize]
          devices
          run [--path PATH] [--show-transcript] [--shadow-synthesize-prefix]
              [--shadow-endpoint-ms 100...3000] [--shadow-smart-turn]
          replay INPUT.wav [--path PATH] [--synthesize] [--live-output]
              [--shadow-synthesize-prefix] [--shadow-endpoint-ms 100...3000]
              [--shadow-early-finalize-ms 100...3000] [--shadow-smart-turn]
          report [SESSION|latest] [--path PATH] [--json]
        """
}

enum CLIExecutionError: Error {
    case configurationExists
    case exampleConfigurationUnavailable
    case permissionDenied
    case noTelemetry
    case invalidOutput
}
