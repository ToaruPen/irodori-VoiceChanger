import AVFAudio
import Foundation
import IrodoriVoiceChangerCore
import IrodoriVoiceChangerMacOS
import Speech

extension CLIApplication {
    static func performReplay(
        input: String,
        configuration: AppConfiguration,
        synthesize: Bool,
        liveOutput: Bool,
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
        let inputs: AsyncStream<AnalyzerInput>
        do {
            inputs = try AudioFileReplay.inputs(
                from: URL(filePath: expand(input)),
                analysisFormat: speech.audioFormat,
                maximumBytes: configuration.audio.maximumWAVBytes,
                maximumDurationSeconds: configuration.audio.maximumClipSeconds
            )
        } catch {
            throw StagedRuntimeError(stage: .speech, code: .invalidWAV)
        }
        let events = try await speech.events(from: inputs)
        if synthesize {
            try await synthesizeReplay(
                events: events,
                configuration: configuration,
                liveOutput: liveOutput,
                recorder: recorder,
                clock: clock,
                sessionID: sessionID
            )
        } else {
            await recordSession(
                .sessionReady, sessionID: sessionID, recorder: recorder, clock: clock)
            do {
                for try await event in events {
                    await recordSpeechOnly(
                        event, sessionID: sessionID, recorder: recorder, clock: clock)
                }
            } catch {
                throw StagedRuntimeError(stage: .speech, code: .speechUnavailable)
            }
        }
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

    private static func synthesizeReplay(
        events: AsyncThrowingStream<SpeechEvent, Error>,
        configuration: AppConfiguration,
        liveOutput: Bool,
        recorder: any TelemetryRecording,
        clock: any MonotonicClock,
        sessionID: UUID
    ) async throws {
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
        let pipeline = VoiceChangerPipeline(
            sessionID: sessionID,
            synthesizer: synthesizer,
            player: player,
            telemetry: recorder,
            clock: clock,
            maximumPendingSynthesis: configuration.queues.pendingSynthesis,
            maximumPendingPlayback: configuration.queues.pendingPlayback
        )
        await recordSession(.sessionReady, sessionID: sessionID, recorder: recorder, clock: clock)
        do {
            for try await event in events {
                await pipeline.handle(event)
            }
        } catch {
            throw StagedRuntimeError(stage: .speech, code: .speechUnavailable)
        }
        await pipeline.stop()
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
