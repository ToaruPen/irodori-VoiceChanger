import AVFAudio
import Foundation
import IrodoriVoiceChangerCore
import IrodoriVoiceChangerMacOS
import IrodoriVoiceChangerSmartTurn
import Speech

extension CLIApplication {
    struct ReplayOptions {
        let input: String
        let synthesize: Bool
        let liveOutput: Bool
        let shadowSynthesizePrefix: Bool
        let endpointShadowMilliseconds: Int?
        let earlyFinalizeShadowMilliseconds: Int?
        let smartTurnShadow: Bool
    }

    private struct ReplaySynthesisResources {
        let synthesizer: ConfiguredIrodoriSynthesizer
        let player: any AudioPlaying
    }

    struct ReplayEndpointResources {
        let finalizationHandler: EndpointFinalizationHandler?
        let semanticHandler: SemanticEndpointHandler?
        let queue: EndpointShadowQueue?
    }

    static func performReplay(
        options: ReplayOptions,
        configuration: AppConfiguration,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock,
        sessionID: UUID
    ) async throws {
        let speech = try await prepareReplaySpeech(
            configuration: configuration,
            recorder: recorder,
            clock: clock,
            sessionID: sessionID
        )
        // AudioFileReplay starts producing at construction, so slow Irodori/output
        // preflight must finish before the input stream exists.
        let synthesisResources: ReplaySynthesisResources?
        if options.synthesize {
            synthesisResources = try await prepareReplaySynthesis(
                configuration: configuration,
                recorder: recorder,
                clock: clock,
                sessionID: sessionID,
                liveOutput: options.liveOutput
            )
        } else {
            synthesisResources = nil
        }
        let endpoint = try makeReplayEndpointResources(
            options: options,
            speech: speech,
            sessionID: sessionID,
            recorder: recorder,
            clock: clock
        )
        let endpointShadow = endpoint.queue
        endpointShadow?.start()
        let activityObserver = endpointActivityObserver(endpointShadow)
        let inputs: AsyncStream<AnalyzerInput>
        do {
            inputs = try AudioFileReplay.inputs(
                from: URL(filePath: expand(options.input)),
                analysisFormat: speech.audioFormat,
                maximumBytes: configuration.audio.maximumWAVBytes,
                maximumDurationSeconds: configuration.audio.maximumClipSeconds,
                activityObserver: activityObserver
            )
        } catch {
            await endpointShadow?.cancel()
            throw StagedRuntimeError(stage: .speech, code: .invalidWAV)
        }
        let events: AsyncThrowingStream<SpeechEvent, Error>
        do {
            events = try await speech.events(from: inputs)
        } catch {
            await endpointShadow?.cancel()
            throw StagedRuntimeError(stage: .speech, code: .speechUnavailable)
        }
        if let synthesisResources {
            let pipeline = makeReplayPipeline(
                options: options,
                configuration: configuration,
                resources: synthesisResources,
                recorder: recorder,
                clock: clock,
                sessionID: sessionID
            )
            try await synthesizeReplay(
                events: events,
                pipeline: pipeline,
                endpointShadow: endpointShadow,
                recorder: recorder,
                clock: clock,
                sessionID: sessionID
            )
        } else {
            let shadow = shadowMonitor(
                configuration.speech.commitPolicy, sessionID, recorder, clock)
            await recordSession(
                .sessionReady, sessionID: sessionID, recorder: recorder, clock: clock)
            try await consumeSpeechOnlyReplay(
                events: events,
                shadow: shadow,
                endpoint: endpoint,
                recorder: recorder,
                clock: clock,
                sessionID: sessionID
            )
        }
    }

    static func consumeSpeechOnlyReplay(
        events: AsyncThrowingStream<SpeechEvent, Error>,
        shadow: StablePrefixShadowMonitor?,
        endpoint: ReplayEndpointResources,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock,
        sessionID: UUID
    ) async throws {
        let endpointShadow = endpoint.queue
        do {
            for try await event in events {
                await shadow?.observe(event)
                endpointShadow?.observe(event)
                await recordSpeechOnly(
                    event, sessionID: sessionID, recorder: recorder, clock: clock)
            }
        } catch {
            await shadow?.cancel()
            await endpointShadow?.cancel()
            throw StagedRuntimeError(stage: .speech, code: .speechUnavailable)
        }
        await shadow?.stop()
        await endpointShadow?.stop()
        if let failure = await endpoint.finalizationHandler?.failureRequiringStop() {
            throw PipelineOperationError(failure)
        }
        if let failure = await endpoint.semanticHandler?.failureRequiringStop() {
            throw PipelineOperationError(failure)
        }
    }

    private static func makeReplayEndpointResources(
        options: ReplayOptions,
        speech: AppleSpeechSession,
        sessionID: UUID,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock
    ) throws -> ReplayEndpointResources {
        let finalizationHandler: EndpointFinalizationHandler? =
            options.earlyFinalizeShadowMilliseconds != nil
            ? EndpointFinalizationHandler(
                sessionID: sessionID,
                telemetry: recorder,
                clock: clock,
                operation: { try await speech.finalizeConsumedAudio() }
            ) : nil
        let semanticHandler: SemanticEndpointHandler?
        if options.smartTurnShadow {
            let classifier: SmartTurnClassifier
            do {
                classifier = try SmartTurnClassifier()
            } catch {
                throw StagedRuntimeError(stage: .speech, code: .speechUnavailable)
            }
            semanticHandler = SemanticEndpointHandler(
                sessionID: sessionID,
                classifier: classifier,
                telemetry: recorder,
                clock: clock
            )
        } else {
            semanticHandler = nil
        }
        let queue = endpointShadowQueue(
            options.smartTurnShadow
                ? 700
                : options.endpointShadowMilliseconds ?? options.earlyFinalizeShadowMilliseconds,
            sessionID,
            recorder,
            clock,
            candidateHandler: semanticHandler ?? finalizationHandler
        )
        return ReplayEndpointResources(
            finalizationHandler: finalizationHandler,
            semanticHandler: semanticHandler,
            queue: queue
        )
    }

    private static func prepareReplaySynthesis(
        configuration: AppConfiguration,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock,
        sessionID: UUID,
        liveOutput: Bool
    ) async throws -> ReplaySynthesisResources {
        let started = clock.nowNanoseconds()
        let synthesizer: ConfiguredIrodoriSynthesizer
        do {
            synthesizer = try await prepareSynthesizer(configuration)
        } catch {
            throw StagedRuntimeError(stage: .irodori, code: stableCode(for: error))
        }
        await recordPreflight(
            stage: .irodori,
            since: started,
            sessionID: sessionID,
            recorder: recorder,
            clock: clock
        )
        let player = try await replayPlayer(
            configuration: configuration,
            liveOutput: liveOutput,
            recorder: recorder,
            clock: clock,
            sessionID: sessionID
        )
        return ReplaySynthesisResources(synthesizer: synthesizer, player: player)
    }

    private static func prepareReplaySpeech(
        configuration: AppConfiguration,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock,
        sessionID: UUID
    ) async throws -> AppleSpeechSession {
        let started = clock.nowNanoseconds()
        do {
            let speech = try await AppleSpeechSession.prepare(
                localeIdentifier: configuration.speech.localeIdentifier,
                sensitivity: configuration.speech.detectorSensitivity
            )
            await recordPreflight(
                stage: .speech,
                since: started,
                sessionID: sessionID,
                recorder: recorder,
                clock: clock
            )
            return speech
        } catch {
            throw StagedRuntimeError(stage: .speech, code: .speechUnavailable)
        }
    }

    private static func makeReplayPipeline(
        options: ReplayOptions,
        configuration: AppConfiguration,
        resources: ReplaySynthesisResources,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock,
        sessionID: UUID
    ) -> VoiceChangerPipeline {
        let synthesizer = resources.synthesizer
        let candidateHandler: (any StablePrefixCandidateHandling)? =
            options.shadowSynthesizePrefix
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
            player: resources.player,
            telemetry: recorder,
            clock: clock,
            maximumPendingSynthesis: configuration.queues.pendingSynthesis,
            maximumPendingPlayback: configuration.queues.pendingPlayback,
            shadowMonitor: shadow
        )
    }

    private static func synthesizeReplay(
        events: AsyncThrowingStream<SpeechEvent, Error>,
        pipeline: VoiceChangerPipeline,
        endpointShadow: EndpointShadowQueue?,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock,
        sessionID: UUID
    ) async throws {
        await recordSession(.sessionReady, sessionID: sessionID, recorder: recorder, clock: clock)
        do {
            for try await event in events {
                endpointShadow?.observe(event)
                await pipeline.handle(event)
            }
        } catch {
            await pipeline.cancel()
            await endpointShadow?.cancel()
            throw StagedRuntimeError(stage: .speech, code: .speechUnavailable)
        }
        await pipeline.stop()
        await endpointShadow?.stop()
        if let failure = await pipeline.failureRequiringRestart() {
            let stage: PipelineStage = failure == .outputUnavailable ? .playback : .irodori
            throw StagedRuntimeError(stage: stage, code: failure)
        }
    }

    private static func replayPlayer(
        configuration: AppConfiguration,
        liveOutput: Bool,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock,
        sessionID: UUID
    ) async throws -> any AudioPlaying {
        guard liveOutput else { return DiscardingAudioPlayer() }
        let started = clock.nowNanoseconds()
        do {
            let device = try AudioDeviceCatalog.current().resolveOutput(
                uid: configuration.audio.outputDeviceUID)
            let player = try await CoreAudioPlayer(
                device: device,
                maximumWAVBytes: configuration.audio.maximumWAVBytes,
                maximumClipSeconds: configuration.audio.maximumClipSeconds
            )
            await recordPreflight(
                stage: .coreAudio,
                since: started,
                sessionID: sessionID,
                recorder: recorder,
                clock: clock
            )
            return player
        } catch {
            throw StagedRuntimeError(stage: .coreAudio, code: .outputUnavailable)
        }
    }
}
