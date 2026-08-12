import AVFAudio
import Darwin
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
        case .run(let path, let showTranscript):
            try await runLive(path: path, showTranscript: showTranscript)
            return 0
        case .replay(let input, let path, let synthesize, let liveOutput):
            try await runReplay(
                input: input,
                path: path,
                synthesize: synthesize,
                liveOutput: liveOutput
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

    private static func runLive(path: String?, showTranscript: Bool) async throws {
        let configuration = try await loadRuntimeConfiguration(path: path)
        let recorder = telemetryRecorder(configuration)
        let clock = SystemMonotonicClock()
        let sessionID = UUID()
        await recordSession(.sessionStarted, sessionID: sessionID, recorder: recorder, clock: clock)
        do {
            try await runPreparedLive(
                configuration: configuration,
                showTranscript: showTranscript,
                recorder: recorder,
                clock: clock,
                sessionID: sessionID
            )
        } catch {
            _ = await recorder.record(
                TelemetryEvent(
                    sessionID: sessionID,
                    utteranceID: nil,
                    timestampNanoseconds: clock.nowNanoseconds(),
                    name: .operationFailed,
                    stage: .lifecycle,
                    errorCode: stableCode(for: error)
                ))
            await recordSession(
                .sessionStopped, sessionID: sessionID, recorder: recorder, clock: clock)
            throw error
        }
        await recordSession(.sessionStopped, sessionID: sessionID, recorder: recorder, clock: clock)
    }

    private static func runPreparedLive(
        configuration: AppConfiguration,
        showTranscript: Bool,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock,
        sessionID: UUID
    ) async throws {
        var started = clock.nowNanoseconds()
        guard await requestRequiredPermissions() else {
            throw CLIExecutionError.permissionDenied
        }
        await recordPreflight(
            stage: .lifecycle,
            since: started,
            sessionID: sessionID,
            recorder: recorder,
            clock: clock
        )
        started = clock.nowNanoseconds()
        let speech = try await AppleSpeechSession.prepare(
            localeIdentifier: configuration.speech.localeIdentifier,
            sensitivity: configuration.speech.detectorSensitivity
        )
        await recordPreflight(
            stage: .speech, since: started, sessionID: sessionID, recorder: recorder, clock: clock)
        started = clock.nowNanoseconds()
        let device = try AudioDeviceCatalog.current().resolveOutput(
            uid: configuration.audio.outputDeviceUID)
        let player = try await CoreAudioPlayer(
            device: device,
            maximumWAVBytes: configuration.audio.maximumWAVBytes,
            maximumClipSeconds: configuration.audio.maximumClipSeconds
        )
        await recordPreflight(
            stage: .coreAudio, since: started, sessionID: sessionID, recorder: recorder,
            clock: clock)
        started = clock.nowNanoseconds()
        let synthesizer = try await prepareSynthesizer(configuration)
        await recordPreflight(
            stage: .irodori, since: started, sessionID: sessionID, recorder: recorder, clock: clock)
        let pipeline = VoiceChangerPipeline(
            sessionID: sessionID,
            synthesizer: synthesizer,
            player: player,
            telemetry: recorder,
            clock: clock,
            maximumPendingSynthesis: configuration.queues.pendingSynthesis,
            maximumPendingPlayback: configuration.queues.pendingPlayback
        )
        let microphone = await MicrophoneCapture()
        let microphoneInput = try await microphone.start(
            analysisFormat: speech.audioFormat,
            bufferFrames: AVAudioFrameCount(configuration.speech.inputBufferFrames)
        )
        let events = try await speech.events(from: microphoneInput.stream)
        await recordSession(.sessionReady, sessionID: sessionID, recorder: recorder, clock: clock)
        print("ready: press Control-C to stop")

        let signalTask = Task {
            for await _ in TerminationSignals.stream() {
                await microphone.stop()
                await speech.cancel()
                await pipeline.cancel()
                await player.stop()
                break
            }
        }
        defer { signalTask.cancel() }
        let restartFailures = await pipeline.restartFailures()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await event in events {
                        if showTranscript { printTranscript(event) }
                        await pipeline.handle(event)
                    }
                }
                group.addTask {
                    for await failure in restartFailures {
                        throw PipelineOperationError(failure)
                    }
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch is CancellationError {
            // Normal shutdown through the signal task.
        } catch {
            await microphone.stop()
            await speech.cancel()
            await pipeline.stop()
            await player.stop()
            throw error
        }
        await pipeline.stop()
        await player.stop()
        if microphoneInput.droppedBufferCount > 0 {
            await recordInputDrops(
                microphoneInput.droppedBufferCount,
                sessionID: sessionID,
                recorder: recorder,
                clock: clock
            )
        }
        if let failure = await pipeline.failureRequiringRestart() {
            throw PipelineOperationError(failure)
        }
    }

    static func runReplay(
        input: String,
        path: String?,
        synthesize: Bool,
        liveOutput: Bool
    ) async throws {
        guard !liveOutput || synthesize else { throw CLIUsageError() }
        let configuration = try await loadRuntimeConfiguration(path: path)
        let recorder = telemetryRecorder(configuration)
        let clock = SystemMonotonicClock()
        let sessionID = UUID()
        await recordSession(.sessionStarted, sessionID: sessionID, recorder: recorder, clock: clock)
        do {
            try await performReplay(
                input: input,
                configuration: configuration,
                synthesize: synthesize,
                liveOutput: liveOutput,
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

    private static func requestRequiredPermissions() async -> Bool {
        let microphone =
            AppPermissions.microphone == .authorized
            ? .authorized : await AppPermissions.requestMicrophone()
        return microphone == .authorized
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

    private static func recordInputDrops(
        _ count: Int,
        sessionID: UUID,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock
    ) async {
        _ = await recorder.record(
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: nil,
                timestampNanoseconds: clock.nowNanoseconds(),
                name: .inputDropped,
                stage: .speech,
                metrics: .init(dropCount: count)
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

    private static func printTranscript(_ event: SpeechEvent) {
        switch event {
        case .partial(_, let text, _): print("partial\t\(text)")
        case .final(_, let text, _): print("final\t\(text)")
        case .speechStarted, .speechEnded, .timing: break
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
          run [--path PATH] [--show-transcript]
          replay INPUT.wav [--path PATH] [--synthesize] [--live-output]
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
