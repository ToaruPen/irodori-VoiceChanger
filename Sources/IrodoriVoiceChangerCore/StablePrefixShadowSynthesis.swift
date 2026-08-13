import Foundation

public actor DiscardingStablePrefixSynthesizer: StablePrefixCandidateHandling {
    private let sessionID: UUID
    private let synthesizer: any Synthesizing
    private let telemetry: any TelemetryRecording
    private let clock: any MonotonicClock
    private var candidates = [UUID: String]()
    private var tasks = [UUID: Task<Void, Never>]()
    private var requestStartedAt = [UUID: UInt64]()
    private var serverMetrics = [UUID: ServerMetrics]()
    private var pendingFinalComparisons = [TelemetryEvent]()

    public init(
        sessionID: UUID,
        synthesizer: any Synthesizing,
        telemetry: any TelemetryRecording,
        clock: any MonotonicClock
    ) {
        self.sessionID = sessionID
        self.synthesizer = synthesizer
        self.telemetry = telemetry
        self.clock = clock
    }

    public func submit(candidate: String, utteranceID: UUID) async {
        let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, candidates[utteranceID] == nil else { return }
        candidates[utteranceID] = normalized
        requestStartedAt[utteranceID] = clock.nowNanoseconds()
        await emit(.shadowSynthesisStarted, utteranceID: utteranceID)

        let owner = self
        tasks[utteranceID] = Task { [owner, synthesizer] in
            do {
                let audio = try await synthesizer.synthesize(
                    text: normalized,
                    utteranceID: utteranceID,
                    onMilestone: { milestone in
                        guard !Task.isCancelled else { return }
                        await owner.record(milestone, utteranceID: utteranceID)
                    }
                )
                guard !Task.isCancelled else { throw CancellationError() }
                await owner.complete(audio, utteranceID: utteranceID)
            } catch is CancellationError {
                await owner.cancelled(utteranceID: utteranceID)
            } catch {
                await owner.fail(error, utteranceID: utteranceID)
            }
        }
    }

    public func finish(final: String, utteranceID: UUID) async {
        guard let candidate = candidates.removeValue(forKey: utteranceID) else { return }
        tasks[utteranceID]?.cancel()
        let comparison = bucketedPrefixComparison(
            candidate: Array(candidate.trimmingCharacters(in: .whitespacesAndNewlines)),
            final: Array(final.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        pendingFinalComparisons.append(
            telemetryEvent(
                .shadowSynthesisFinalComparison,
                utteranceID: utteranceID,
                metrics: .init(
                    shadowCandidatePresent: true,
                    shadowCandidateMatchRatio: comparison.match,
                    shadowFinalCoverageRatio: comparison.coverage
                )
            )
        )
    }

    public func stop() async {
        let activeTasks = Array(tasks.values)
        for task in activeTasks {
            await task.value
        }
        tasks.removeAll()
        await flushPendingFinalComparisons()
    }

    public func cancel() async {
        let activeTasks = Array(tasks.values)
        activeTasks.forEach { $0.cancel() }
        for task in activeTasks {
            await task.value
        }
        tasks.removeAll()
        candidates.removeAll()
        await flushPendingFinalComparisons()
    }

    private func record(_ milestone: SynthesisMilestone, utteranceID: UUID) async {
        switch milestone {
        case .handshake:
            await emit(.shadowSynthesisHandshake, utteranceID: utteranceID)
        case .firstAudioPayload:
            await emit(.shadowSynthesisFirstAudio, utteranceID: utteranceID)
        case .completed(let serverElapsedMilliseconds, let samplingSteps):
            serverMetrics[utteranceID] = ServerMetrics(
                durationMilliseconds: serverElapsedMilliseconds,
                samplingSteps: samplingSteps
            )
        }
    }

    private func complete(_ audio: AudioClip, utteranceID: UUID) async {
        let server = serverMetrics.removeValue(forKey: utteranceID)
        await emit(
            .shadowSynthesisCompleted,
            utteranceID: utteranceID,
            metrics: .init(
                durationMilliseconds: elapsedMilliseconds(
                    since: requestStartedAt.removeValue(forKey: utteranceID)),
                audioDurationMilliseconds: audio.durationMilliseconds,
                serverDurationMilliseconds: server?.durationMilliseconds,
                byteCount: audio.wavBytes.count,
                samplingSteps: server?.samplingSteps
            )
        )
        tasks.removeValue(forKey: utteranceID)
    }

    private func cancelled(utteranceID: UUID) async {
        requestStartedAt.removeValue(forKey: utteranceID)
        serverMetrics.removeValue(forKey: utteranceID)
        await emit(.shadowSynthesisCancelled, utteranceID: utteranceID)
        tasks.removeValue(forKey: utteranceID)
    }

    private func fail(_ error: Error, utteranceID: UUID) async {
        requestStartedAt.removeValue(forKey: utteranceID)
        serverMetrics.removeValue(forKey: utteranceID)
        await emit(
            .shadowSynthesisFailed,
            utteranceID: utteranceID,
            errorCode: stableCode(for: error)
        )
        tasks.removeValue(forKey: utteranceID)
    }

    private func emit(
        _ name: TelemetryEventName,
        utteranceID: UUID,
        errorCode: StableErrorCode? = nil,
        metrics: TelemetryMetrics = .init()
    ) async {
        _ = await telemetry.record(
            telemetryEvent(
                name,
                utteranceID: utteranceID,
                errorCode: errorCode,
                metrics: metrics
            ))
    }

    private func telemetryEvent(
        _ name: TelemetryEventName,
        utteranceID: UUID,
        errorCode: StableErrorCode? = nil,
        metrics: TelemetryMetrics = .init()
    ) -> TelemetryEvent {
        TelemetryEvent(
            sessionID: sessionID,
            utteranceID: utteranceID,
            timestampNanoseconds: clock.nowNanoseconds(),
            name: name,
            stage: .irodori,
            errorCode: errorCode,
            metrics: metrics
        )
    }

    private func flushPendingFinalComparisons() async {
        let comparisons = pendingFinalComparisons
        pendingFinalComparisons.removeAll()
        for comparison in comparisons {
            _ = await telemetry.record(comparison)
        }
    }

    private func elapsedMilliseconds(since start: UInt64?) -> Double? {
        guard let start else { return nil }
        return Double(clock.nowNanoseconds() - start) / 1_000_000
    }
}

private struct ServerMetrics: Sendable {
    let durationMilliseconds: Double?
    let samplingSteps: Int?
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
