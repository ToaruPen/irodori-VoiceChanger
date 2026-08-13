import Foundation

public enum SpeechEvent: Equatable, Sendable {
    case speechStarted(UUID)
    case partial(UUID, text: String, revisionCount: Int)
    case speechEnded(UUID)
    case final(UUID, text: String, revisionCount: Int)
    case timing(UUID, kind: SpeechTimingKind, deliveryMilliseconds: Double)
}

public enum SpeechTimingKind: String, Equatable, Sendable {
    case partial
    case final
    case speechEnd = "speech_end"
}

public struct AudioClip: Equatable, Sendable {
    public let wavBytes: Data
    public let durationMilliseconds: Double

    public init(wavBytes: Data, durationMilliseconds: Double) {
        self.wavBytes = wavBytes
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct PipelineOperationError: Error, Equatable, Sendable {
    public let code: StableErrorCode

    public init(_ code: StableErrorCode) {
        self.code = code
    }
}

public protocol SpeechEventSource: Sendable {
    func events() async throws -> AsyncThrowingStream<SpeechEvent, Error>
}

public protocol Synthesizing: Sendable {
    func synthesize(
        text: String,
        utteranceID: UUID,
        onMilestone: @Sendable (SynthesisMilestone) async -> Void
    ) async throws -> AudioClip
}

public protocol AudioPlaying: Sendable {
    func play(_ audio: AudioClip, utteranceID: UUID) async throws
}

public actor VoiceChangerPipeline {
    private let sessionID: UUID
    private let synthesizer: any Synthesizing
    private let player: any AudioPlaying
    private let telemetry: any TelemetryRecording
    private let clock: any MonotonicClock
    private let maximumPendingSynthesis: Int
    private let maximumPendingPlayback: Int
    private let shadowMonitor: StablePrefixShadowMonitor?

    private var pendingSynthesis = [CommittedUtterance]()
    private var pendingPlayback = [QueuedAudio]()
    private var synthesisRunning = false
    private var playbackRunning = false
    private var acceptingEvents = true
    private var cancellationRequested = false
    private var synthesisTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var idleContinuations = [CheckedContinuation<Void, Never>]()
    private var requestStartedAt = [UUID: UInt64]()
    private var playbackEnqueuedAt = [UUID: UInt64]()
    private var consecutiveRemoteFailures = 0
    private var restartFailure: StableErrorCode?
    private var activeSynthesisID: UUID?
    private var restartContinuations = [UUID: AsyncStream<StableErrorCode>.Continuation]()

    public init(
        sessionID: UUID = UUID(),
        synthesizer: any Synthesizing,
        player: any AudioPlaying,
        telemetry: any TelemetryRecording,
        clock: any MonotonicClock,
        maximumPendingSynthesis: Int,
        maximumPendingPlayback: Int,
        shadowMonitor: StablePrefixShadowMonitor? = nil
    ) {
        self.sessionID = sessionID
        self.synthesizer = synthesizer
        self.player = player
        self.telemetry = telemetry
        self.clock = clock
        self.maximumPendingSynthesis = maximumPendingSynthesis
        self.maximumPendingPlayback = maximumPendingPlayback
        self.shadowMonitor = shadowMonitor
    }

    public func run(source: any SpeechEventSource) async throws {
        for try await event in try await source.events() {
            await handle(event)
        }
        await stop()
    }

    public func handle(_ event: SpeechEvent) async {
        guard acceptingEvents else { return }
        await shadowMonitor?.observe(event)
        switch event {
        case .speechStarted(let utteranceID):
            await emit(.speechStarted, utteranceID: utteranceID, stage: .speech)
        case .partial(let utteranceID, _, let revisionCount):
            await emit(
                .asrPartial,
                utteranceID: utteranceID,
                stage: .speech,
                metrics: .init(partialRevisionCount: revisionCount)
            )
        case .speechEnded(let utteranceID):
            await emit(.speechEnded, utteranceID: utteranceID, stage: .speech)
        case .final(let utteranceID, let text, let revisionCount):
            await acceptFinal(
                utteranceID: utteranceID,
                text: text,
                revisionCount: revisionCount
            )
        case .timing(let utteranceID, let kind, let deliveryMilliseconds):
            let name: TelemetryEventName =
                switch kind {
                case .partial: .asrPartialTiming
                case .final: .asrFinalTiming
                case .speechEnd: .speechEndTiming
                }
            await emit(
                name,
                utteranceID: utteranceID,
                stage: .speech,
                metrics: .init(sourceLatencyMilliseconds: deliveryMilliseconds)
            )
        }
    }

    public func stop() async {
        acceptingEvents = false
        await waitUntilIdle()
        await shadowMonitor?.stop()
    }

    public func cancel() async {
        guard !cancellationRequested else { return }
        acceptingEvents = false
        cancellationRequested = true
        let synthesis = pendingSynthesis
        let playback = pendingPlayback
        pendingSynthesis.removeAll()
        pendingPlayback.removeAll()
        synthesisTask?.cancel()
        playbackTask?.cancel()
        await shadowMonitor?.cancel()
        for utterance in synthesis {
            await emit(.utteranceDropped, utteranceID: utterance.id, stage: .commit)
        }
        for queued in playback {
            playbackEnqueuedAt.removeValue(forKey: queued.id)
            await emit(.utteranceDropped, utteranceID: queued.id, stage: .playback)
        }
        resumeIdleWaitersIfNeeded()
    }

    public func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { continuation in
            idleContinuations.append(continuation)
        }
    }

    public func failureRequiringRestart() -> StableErrorCode? {
        restartFailure
    }

    public func restartFailures() -> AsyncStream<StableErrorCode> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: StableErrorCode.self)
        if let restartFailure {
            continuation.yield(restartFailure)
            continuation.finish()
        } else {
            restartContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeRestartContinuation(id) }
            }
        }
        return stream
    }

    private var isIdle: Bool {
        !synthesisRunning && !playbackRunning && pendingSynthesis.isEmpty && pendingPlayback.isEmpty
    }

    private func acceptFinal(utteranceID: UUID, text: String, revisionCount: Int) async {
        await emit(
            .asrFinal,
            utteranceID: utteranceID,
            stage: .speech,
            metrics: .init(partialRevisionCount: revisionCount)
        )
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            await emit(.utteranceDropped, utteranceID: utteranceID, stage: .commit)
            return
        }
        guard pendingSynthesis.count < maximumPendingSynthesis else {
            await emit(
                .utteranceDropped,
                utteranceID: utteranceID,
                stage: .commit,
                metrics: .init(queueDepth: pendingSynthesis.count)
            )
            return
        }
        pendingSynthesis.append(.init(id: utteranceID, text: normalized))
        await emit(
            .utteranceCommitted,
            utteranceID: utteranceID,
            stage: .commit,
            metrics: .init(queueDepth: pendingSynthesis.count)
        )
        startSynthesisWorkerIfNeeded()
    }

    private func startSynthesisWorkerIfNeeded() {
        guard !synthesisRunning, !pendingSynthesis.isEmpty, !cancellationRequested,
            restartFailure == nil
        else { return }
        synthesisRunning = true
        synthesisTask = Task { await self.synthesisLoop() }
    }

    private func synthesisLoop() async {
        while !pendingSynthesis.isEmpty {
            let utterance = pendingSynthesis.removeFirst()
            activeSynthesisID = utterance.id
            let requestStart = clock.nowNanoseconds()
            requestStartedAt[utterance.id] = requestStart
            await emit(.requestStarted, utteranceID: utterance.id, stage: .irodori)
            do {
                let audio = try await synthesizer.synthesize(
                    text: utterance.text,
                    utteranceID: utterance.id,
                    onMilestone: { [weak self] milestone in
                        await self?.record(milestone: milestone, utteranceID: utterance.id)
                    }
                )
                consecutiveRemoteFailures = 0
                activeSynthesisID = nil
                guard !cancellationRequested, restartFailure == nil else {
                    requestStartedAt.removeValue(forKey: utterance.id)
                    await emit(.utteranceDropped, utteranceID: utterance.id, stage: .irodori)
                    continue
                }
                await enqueuePlayback(audio, utteranceID: utterance.id)
            } catch {
                activeSynthesisID = nil
                requestStartedAt.removeValue(forKey: utterance.id)
                if Task.isCancelled && (cancellationRequested || restartFailure != nil) {
                    await emit(.utteranceDropped, utteranceID: utterance.id, stage: .irodori)
                    continue
                }
                let code = stableCode(for: error)
                await emit(
                    .operationFailed,
                    utteranceID: utterance.id,
                    stage: .irodori,
                    errorCode: code
                )
                consecutiveRemoteFailures += 1
                if code == .runtimeGenerationMismatch || consecutiveRemoteFailures >= 3 {
                    await stopForRestart(code)
                }
            }
        }
        synthesisRunning = false
        synthesisTask = nil
        resumeIdleWaitersIfNeeded()
    }

    private func record(milestone: SynthesisMilestone, utteranceID: UUID) async {
        guard !cancellationRequested, restartFailure == nil else { return }
        switch milestone {
        case .handshake:
            await emit(.streamHandshake, utteranceID: utteranceID, stage: .irodori)
        case .firstAudioPayload:
            await emit(.firstAudioPayload, utteranceID: utteranceID, stage: .irodori)
        case .completed(let serverElapsedMilliseconds, let samplingSteps):
            let duration = elapsedMilliseconds(
                since: requestStartedAt.removeValue(forKey: utteranceID))
            await emit(
                .requestCompleted,
                utteranceID: utteranceID,
                stage: .irodori,
                metrics: .init(
                    durationMilliseconds: duration,
                    serverDurationMilliseconds: serverElapsedMilliseconds,
                    samplingSteps: samplingSteps
                )
            )
        }
    }

    private func enqueuePlayback(_ audio: AudioClip, utteranceID: UUID) async {
        guard pendingPlayback.count < maximumPendingPlayback else {
            await emit(
                .utteranceDropped,
                utteranceID: utteranceID,
                stage: .playback,
                metrics: .init(queueDepth: pendingPlayback.count)
            )
            return
        }
        pendingPlayback.append(.init(id: utteranceID, audio: audio))
        playbackEnqueuedAt[utteranceID] = clock.nowNanoseconds()
        await emit(
            .playbackEnqueued,
            utteranceID: utteranceID,
            stage: .playback,
            metrics: .init(
                audioDurationMilliseconds: audio.durationMilliseconds,
                queueDepth: pendingPlayback.count,
                byteCount: audio.wavBytes.count
            )
        )
        startPlaybackWorkerIfNeeded()
    }

    private func startPlaybackWorkerIfNeeded() {
        guard !playbackRunning, !pendingPlayback.isEmpty, !cancellationRequested,
            restartFailure == nil
        else { return }
        playbackRunning = true
        playbackTask = Task { await self.playbackLoop() }
    }

    private func playbackLoop() async {
        while !pendingPlayback.isEmpty {
            let queued = pendingPlayback.removeFirst()
            let queuedDuration = elapsedMilliseconds(
                since: playbackEnqueuedAt.removeValue(forKey: queued.id))
            await emit(
                .playbackStarted,
                utteranceID: queued.id,
                stage: .playback,
                metrics: .init(durationMilliseconds: queuedDuration)
            )
            guard !cancellationRequested, restartFailure == nil, !Task.isCancelled else {
                await emit(.utteranceDropped, utteranceID: queued.id, stage: .playback)
                continue
            }
            let playbackStart = clock.nowNanoseconds()
            do {
                try await player.play(queued.audio, utteranceID: queued.id)
                if cancellationRequested {
                    await emit(.utteranceDropped, utteranceID: queued.id, stage: .playback)
                } else {
                    await emit(
                        .playbackCompleted,
                        utteranceID: queued.id,
                        stage: .playback,
                        metrics: .init(
                            durationMilliseconds: elapsedMilliseconds(since: playbackStart))
                    )
                }
                if !cancellationRequested, restartFailure == nil, pendingPlayback.isEmpty,
                    activeSynthesisID != nil || !pendingSynthesis.isEmpty
                {
                    await emit(
                        .queueUnderrun,
                        utteranceID: queued.id,
                        stage: .playback,
                        metrics: .init(queueDepth: pendingPlayback.count)
                    )
                }
            } catch {
                if Task.isCancelled && (cancellationRequested || restartFailure != nil) {
                    await emit(.utteranceDropped, utteranceID: queued.id, stage: .playback)
                    continue
                }
                let code = stableCode(for: error)
                await emit(
                    .operationFailed,
                    utteranceID: queued.id,
                    stage: .playback,
                    errorCode: code
                )
                await stopForRestart(code)
            }
        }
        playbackRunning = false
        playbackTask = nil
        resumeIdleWaitersIfNeeded()
    }

    private func stopForRestart(_ code: StableErrorCode) async {
        guard restartFailure == nil else { return }
        restartFailure = code
        let continuations = restartContinuations.values
        restartContinuations.removeAll()
        for continuation in continuations {
            continuation.yield(code)
            continuation.finish()
        }
        acceptingEvents = false
        synthesisTask?.cancel()
        playbackTask?.cancel()
        await shadowMonitor?.cancel()
        let synthesis = pendingSynthesis
        let playback = pendingPlayback
        pendingSynthesis.removeAll()
        pendingPlayback.removeAll()
        for utterance in synthesis {
            await emit(.utteranceDropped, utteranceID: utterance.id, stage: .commit)
        }
        for queued in playback {
            playbackEnqueuedAt.removeValue(forKey: queued.id)
            await emit(.utteranceDropped, utteranceID: queued.id, stage: .playback)
        }
    }

    private func removeRestartContinuation(_ id: UUID) {
        restartContinuations.removeValue(forKey: id)
    }

    private func emit(
        _ name: TelemetryEventName,
        utteranceID: UUID?,
        stage: PipelineStage,
        errorCode: StableErrorCode? = nil,
        metrics: TelemetryMetrics = .init()
    ) async {
        _ = await telemetry.record(
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: utteranceID,
                timestampNanoseconds: clock.nowNanoseconds(),
                name: name,
                stage: stage,
                errorCode: errorCode,
                metrics: metrics
            )
        )
    }

    private func elapsedMilliseconds(since start: UInt64?) -> Double? {
        guard let start else { return nil }
        return Double(clock.nowNanoseconds() - start) / 1_000_000
    }

    private func stableCode(for error: Error) -> StableErrorCode {
        if let operationError = error as? PipelineOperationError {
            return operationError.code
        }
        if let clientError = error as? IrodoriClientError {
            return clientError.stableCode
        }
        return .invalidResponse
    }

    private func resumeIdleWaitersIfNeeded() {
        guard isIdle else { return }
        let continuations = idleContinuations
        idleContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private struct CommittedUtterance: Sendable {
    let id: UUID
    let text: String
}

private struct QueuedAudio: Sendable {
    let id: UUID
    let audio: AudioClip
}
