import Foundation

public enum StablePrefixShadowOutcome: Equatable, Sendable {
    case candidateAdvanced
    case rewrite
    case rollback
    case finalComparison(
        candidatePresent: Bool,
        candidateMatchRatio: Double,
        finalCoverageRatio: Double
    )
}

public protocol StablePrefixCandidateHandling: Sendable {
    func submit(candidate: String, utteranceID: UUID) async
    func finish(final: String, utteranceID: UUID) async
    func stop() async
    func cancel() async
}

public struct StablePrefixShadowEvaluator: Sendable {
    private let minimumObservations: Int
    private let minimumStableNanoseconds: UInt64
    private var previousPartial = [Character]()
    private var observations = [PositionObservation]()
    private var candidateLength = 0

    public init(minimumObservations: Int, minimumStableNanoseconds: UInt64) {
        self.minimumObservations = minimumObservations
        self.minimumStableNanoseconds = minimumStableNanoseconds
    }

    public var candidateText: String? {
        guard candidateLength > 0 else { return nil }
        return String(previousPartial.prefix(candidateLength))
    }

    public mutating func observePartial(
        _ text: String,
        at timestampNanoseconds: UInt64
    ) -> [StablePrefixShadowOutcome] {
        let current = normalizedCharacters(text)
        guard !current.isEmpty else { return [] }

        let commonLength = commonPrefixLength(previousPartial, current)
        var outcomes = [StablePrefixShadowOutcome]()
        if !previousPartial.isEmpty, commonLength < previousPartial.count {
            outcomes.append(.rewrite)
        }
        if commonLength < candidateLength {
            outcomes.append(.rollback)
        }

        observations = current.indices.map { index in
            if index < commonLength {
                let prior = observations[index]
                return PositionObservation(
                    consecutiveCount: prior.consecutiveCount + 1,
                    firstObservedAt: prior.firstObservedAt
                )
            }
            return PositionObservation(
                consecutiveCount: 1,
                firstObservedAt: timestampNanoseconds
            )
        }
        previousPartial = current

        let previousCandidateLength = candidateLength
        candidateLength = stablePrefixLength(at: timestampNanoseconds)
        if candidateLength > previousCandidateLength {
            outcomes.append(.candidateAdvanced)
        }
        return outcomes
    }

    public func observeFinal(_ text: String) -> [StablePrefixShadowOutcome] {
        let final = normalizedCharacters(text)
        let candidate = Array(previousPartial.prefix(candidateLength))
        let matchingLength = commonPrefixLength(candidate, final)
        let comparison = bucketedPrefixComparison(candidate: candidate, final: final)
        var outcomes = [StablePrefixShadowOutcome]()
        if matchingLength < candidate.count {
            outcomes.append(.rollback)
        }
        outcomes.append(
            .finalComparison(
                candidatePresent: !candidate.isEmpty,
                candidateMatchRatio: comparison.match,
                finalCoverageRatio: comparison.coverage
            ))
        return outcomes
    }

    private func stablePrefixLength(at timestampNanoseconds: UInt64) -> Int {
        var length = 0
        for observation in observations {
            guard observation.consecutiveCount >= minimumObservations,
                timestampNanoseconds >= observation.firstObservedAt,
                timestampNanoseconds - observation.firstObservedAt >= minimumStableNanoseconds
            else {
                break
            }
            length += 1
        }
        return length
    }
}

public actor StablePrefixShadowMonitor {
    private let sessionID: UUID
    private let minimumObservations: Int
    private let minimumStableNanoseconds: UInt64
    private let telemetry: any TelemetryRecording
    private let clock: any MonotonicClock
    private let candidateHandler: (any StablePrefixCandidateHandling)?
    private var evaluators = [UUID: StablePrefixShadowEvaluator]()
    private var submittedCandidateIDs = Set<UUID>()
    private var pendingFinalEvents = [TelemetryEvent]()

    public init(
        sessionID: UUID,
        minimumObservations: Int,
        minimumStableMilliseconds: Int,
        telemetry: any TelemetryRecording,
        clock: any MonotonicClock,
        candidateHandler: (any StablePrefixCandidateHandling)? = nil
    ) {
        self.sessionID = sessionID
        self.minimumObservations = minimumObservations
        self.minimumStableNanoseconds =
            UInt64(max(0, minimumStableMilliseconds)) * 1_000_000
        self.telemetry = telemetry
        self.clock = clock
        self.candidateHandler = candidateHandler
    }

    public func observe(_ event: SpeechEvent) async {
        switch event {
        case .speechStarted(let utteranceID):
            evaluators[utteranceID] = newEvaluator()
            submittedCandidateIDs.remove(utteranceID)
        case .partial(let utteranceID, let text, _):
            let timestamp = clock.nowNanoseconds()
            var evaluator = evaluators[utteranceID] ?? newEvaluator()
            let outcomes = evaluator.observePartial(text, at: timestamp)
            evaluators[utteranceID] = evaluator
            await record(outcomes, utteranceID: utteranceID, timestamp: timestamp)
            if outcomes.contains(.candidateAdvanced),
                submittedCandidateIDs.insert(utteranceID).inserted,
                let candidate = evaluator.candidateText
            {
                await candidateHandler?.submit(candidate: candidate, utteranceID: utteranceID)
            }
        case .final(let utteranceID, let text, _):
            let timestamp = clock.nowNanoseconds()
            let evaluator = evaluators.removeValue(forKey: utteranceID) ?? newEvaluator()
            await candidateHandler?.finish(final: text, utteranceID: utteranceID)
            pendingFinalEvents.append(
                contentsOf: telemetryEvents(
                    for: evaluator.observeFinal(text),
                    utteranceID: utteranceID,
                    timestamp: timestamp
                )
            )
            submittedCandidateIDs.remove(utteranceID)
        case .speechEnded, .timing:
            break
        }
    }

    public func stop() async {
        await candidateHandler?.stop()
        await flushPendingFinalEvents()
    }

    public func cancel() async {
        await candidateHandler?.cancel()
        await flushPendingFinalEvents()
    }

    private func newEvaluator() -> StablePrefixShadowEvaluator {
        StablePrefixShadowEvaluator(
            minimumObservations: minimumObservations,
            minimumStableNanoseconds: minimumStableNanoseconds
        )
    }

    private func record(
        _ outcomes: [StablePrefixShadowOutcome],
        utteranceID: UUID,
        timestamp: UInt64
    ) async {
        await write(
            telemetryEvents(
                for: outcomes,
                utteranceID: utteranceID,
                timestamp: timestamp
            ))
    }

    private func telemetryEvents(
        for outcomes: [StablePrefixShadowOutcome],
        utteranceID: UUID,
        timestamp: UInt64
    ) -> [TelemetryEvent] {
        outcomes.map { outcome in
            let (name, metrics): (TelemetryEventName, TelemetryMetrics) =
                switch outcome {
                case .candidateAdvanced:
                    (.shadowPrefixCandidate, .init())
                case .rewrite:
                    (.shadowPrefixRewrite, .init())
                case .rollback:
                    (.shadowPrefixRollback, .init())
                case .finalComparison(let present, let match, let coverage):
                    (
                        .shadowFinalComparison,
                        .init(
                            shadowCandidatePresent: present,
                            shadowCandidateMatchRatio: match,
                            shadowFinalCoverageRatio: coverage
                        )
                    )
                }
            return TelemetryEvent(
                sessionID: sessionID,
                utteranceID: utteranceID,
                timestampNanoseconds: timestamp,
                name: name,
                stage: .commit,
                metrics: metrics
            )
        }
    }

    private func write(_ events: [TelemetryEvent]) async {
        for event in events {
            _ = await telemetry.record(event)
        }
    }

    private func flushPendingFinalEvents() async {
        let events = pendingFinalEvents
        pendingFinalEvents.removeAll()
        await write(events)
    }
}

private struct PositionObservation: Sendable {
    let consecutiveCount: Int
    let firstObservedAt: UInt64
}

private func normalizedCharacters(_ text: String) -> [Character] {
    Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

func commonPrefixLength(_ lhs: [Character], _ rhs: [Character]) -> Int {
    var index = 0
    while index < lhs.count, index < rhs.count, lhs[index] == rhs[index] {
        index += 1
    }
    return index
}

func bucketedPrefixComparison(
    candidate: [Character],
    final: [Character]
) -> (match: Double, coverage: Double) {
    let matchingLength = commonPrefixLength(candidate, final)
    return (
        ratio(matchingLength, to: candidate.count),
        ratio(matchingLength, to: final.count)
    )
}

private func ratio(_ numerator: Int, to denominator: Int) -> Double {
    guard denominator > 0 else { return 0 }
    let value = Double(numerator) / Double(denominator)
    return (value * 10).rounded() / 10
}
