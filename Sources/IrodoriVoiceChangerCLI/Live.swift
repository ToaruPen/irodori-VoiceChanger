import AVFAudio
import Foundation
import IrodoriVoiceChangerCore
import IrodoriVoiceChangerMacOS
import IrodoriVoiceChangerSmartTurn

extension CLIApplication {
    struct LiveOptions {
        let showTranscript: Bool
        let shadowSynthesizePrefix: Bool
        let endpointShadowMilliseconds: Int?
        let shadowSmartTurn: Bool
    }

    static func runLive(
        path: String?,
        options: LiveOptions
    ) async throws {
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
            try await runPreparedLive(
                configuration: configuration,
                recorder: recorder,
                clock: clock,
                sessionID: sessionID,
                options: options
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
        recorder: any TelemetryRecording,
        clock: any MonotonicClock,
        sessionID: UUID,
        options: LiveOptions
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
        let pipeline = makeLivePipeline(
            configuration: configuration,
            synthesizer: synthesizer,
            player: player,
            recorder: recorder,
            clock: clock,
            sessionID: sessionID,
            shadowSynthesizePrefix: options.shadowSynthesizePrefix
        )
        let endpointShadow = try makeLiveEndpointQueue(
            options: options,
            sessionID: sessionID,
            recorder: recorder,
            clock: clock
        )
        endpointShadow?.start()
        let (microphone, microphoneInput) = try await startMicrophone(
            speech: speech,
            configuration: configuration,
            endpointShadow: endpointShadow
        )
        let events = try await speech.events(from: microphoneInput.stream)
        await recordSession(.sessionReady, sessionID: sessionID, recorder: recorder, clock: clock)
        print("ready: press Control-C to stop")

        let signalTask = makeSignalTask(microphone, speech, pipeline, player)
        defer { signalTask.cancel() }
        let restartFailures = await pipeline.restartFailures()
        do {
            try await consumeLiveEvents(
                events,
                restartFailures: restartFailures,
                showTranscript: options.showTranscript,
                endpointShadow: endpointShadow,
                pipeline: pipeline
            )
        } catch is CancellationError {
            // Normal shutdown through the signal task.
        } catch {
            await microphone.stop()
            await speech.cancel()
            await pipeline.stop()
            await endpointShadow?.cancel()
            await player.stop()
            throw error
        }
        await pipeline.stop()
        await endpointShadow?.stop()
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

    private static func consumeLiveEvents(
        _ events: AsyncThrowingStream<SpeechEvent, Error>,
        restartFailures: AsyncStream<StableErrorCode>,
        showTranscript: Bool,
        endpointShadow: EndpointShadowQueue?,
        pipeline: VoiceChangerPipeline
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await event in events {
                    if showTranscript { printTranscript(event) }
                    endpointShadow?.observe(event)
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
    }

    private static func makeLiveEndpointQueue(
        options: LiveOptions,
        sessionID: UUID,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock
    ) throws -> EndpointShadowQueue? {
        let semanticHandler: SemanticEndpointHandler?
        if options.shadowSmartTurn {
            let classifier: SmartTurnClassifier
            do {
                classifier = try SmartTurnClassifier()
            } catch {
                throw StagedRuntimeError(stage: .speech, code: .speechUnavailable)
            }
            semanticHandler = makeLiveSemanticHandler(
                options: options,
                classifier: classifier,
                sessionID: sessionID,
                recorder: recorder,
                clock: clock
            )
        } else {
            semanticHandler = nil
        }
        return endpointShadowQueue(
            liveEndpointMilliseconds(options: options),
            sessionID,
            recorder,
            clock,
            candidateHandler: semanticHandler
        )
    }

    static func liveEndpointMilliseconds(options: LiveOptions) -> Int? {
        if options.shadowSmartTurn { return 700 }
        return options.endpointShadowMilliseconds
    }

    static func makeLiveSemanticHandler(
        options: LiveOptions,
        classifier: any SemanticTurnClassifying,
        sessionID: UUID,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock
    ) -> SemanticEndpointHandler? {
        guard options.shadowSmartTurn else { return nil }
        return SemanticEndpointHandler(
            sessionID: sessionID,
            classifier: classifier,
            telemetry: recorder,
            clock: clock
        )
    }

    private static func makeSignalTask(
        _ microphone: MicrophoneCapture,
        _ speech: AppleSpeechSession,
        _ pipeline: VoiceChangerPipeline,
        _ player: CoreAudioPlayer
    ) -> Task<Void, Never> {
        Task {
            for await _ in TerminationSignals.stream() {
                await microphone.stop()
                await speech.cancel()
                await pipeline.cancel()
                await player.stop()
                break
            }
        }
    }

    private static func startMicrophone(
        speech: AppleSpeechSession,
        configuration: AppConfiguration,
        endpointShadow: EndpointShadowQueue?
    ) async throws -> (MicrophoneCapture, MicrophoneInput) {
        let microphone = await MicrophoneCapture()
        let input = try await microphone.start(
            analysisFormat: speech.audioFormat,
            bufferFrames: AVAudioFrameCount(configuration.speech.inputBufferFrames),
            activityObserver: endpointActivityObserver(endpointShadow)
        )
        return (microphone, input)
    }

    private static func makeLivePipeline(
        configuration: AppConfiguration,
        synthesizer: ConfiguredIrodoriSynthesizer,
        player: CoreAudioPlayer,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock,
        sessionID: UUID,
        shadowSynthesizePrefix: Bool
    ) -> VoiceChangerPipeline {
        let candidateHandler: (any StablePrefixCandidateHandling)? =
            shadowSynthesizePrefix
            ? DiscardingStablePrefixSynthesizer(
                sessionID: sessionID,
                synthesizer: synthesizer,
                telemetry: recorder,
                clock: clock
            ) : nil
        let shadow = shadowMonitor(
            configuration.speech.commitPolicy,
            sessionID,
            recorder,
            clock,
            candidateHandler: candidateHandler
        )
        return VoiceChangerPipeline(
            sessionID: sessionID,
            synthesizer: synthesizer,
            player: player,
            telemetry: recorder,
            clock: clock,
            maximumPendingSynthesis: configuration.queues.pendingSynthesis,
            maximumPendingPlayback: configuration.queues.pendingPlayback,
            shadowMonitor: shadow
        )
    }

    private static func requestRequiredPermissions() async -> Bool {
        let microphone =
            AppPermissions.microphone == .authorized
            ? .authorized : await AppPermissions.requestMicrophone()
        return microphone == .authorized
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

    private static func printTranscript(_ event: SpeechEvent) {
        switch event {
        case .partial(_, let text, _): print("partial\t\(text)")
        case .final(_, let text, _): print("final\t\(text)")
        case .speechStarted, .speechEnded, .timing: break
        }
    }
}
