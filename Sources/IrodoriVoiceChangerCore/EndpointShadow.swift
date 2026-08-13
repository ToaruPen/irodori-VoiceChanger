import Foundation

public enum EndpointShadowOutcome: Equatable, Sendable {
    case candidate(candidatePresent: Bool)
    case speechResumed
    case finalComparison(
        candidatePresent: Bool,
        candidateMatchRatio: Double,
        finalCoverageRatio: Double
    )
}

public struct EndpointAudioFrame: Equatable, Sendable {
    public let isSpeech: Bool
    public let durationMilliseconds: Double
    public let sampleRate: Double
    public let samples: [Float]

    public init(
        isSpeech: Bool,
        durationMilliseconds: Double,
        sampleRate: Double,
        samples: [Float]
    ) {
        self.isSpeech = isSpeech
        self.durationMilliseconds = durationMilliseconds
        self.sampleRate = sampleRate
        self.samples = samples
    }
}

public enum EndpointCandidateDisposition: Equatable, Sendable {
    case terminal
    case retryAfterSpeech
}

public protocol EndpointCandidateHandling: Sendable {
    func observeEndpointSpeech(_ event: SpeechEvent) async
    func observeEndpointAudio(_ frame: EndpointAudioFrame) async
    func handleEndpointCandidate(utteranceID: UUID) async -> EndpointCandidateDisposition
    func cancel() async
}

public extension EndpointCandidateHandling {
    func observeEndpointSpeech(_: SpeechEvent) async {}
    func observeEndpointAudio(_: EndpointAudioFrame) async {}
    func cancel() async {}
}

public struct EndpointShadowEvaluator: Sendable {
    private let silenceMilliseconds: Double
    private var trailingSilenceMilliseconds = 0.0
    private var latestPartial: String?
    private var candidate: String?
    private var candidateObserved = false
    private var speechResumptionObserved = false

    public init(silenceMilliseconds: Int) {
        self.silenceMilliseconds = Double(max(0, silenceMilliseconds))
    }

    public mutating func observePartial(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            latestPartial = normalized
        }
    }

    public mutating func observeAudio(
        isSpeech: Bool,
        durationMilliseconds: Double
    ) -> [EndpointShadowOutcome] {
        if isSpeech {
            trailingSilenceMilliseconds = 0
            guard candidateObserved, !speechResumptionObserved else { return [] }
            speechResumptionObserved = true
            return [.speechResumed]
        }
        guard !candidateObserved else { return [] }
        trailingSilenceMilliseconds += max(0, durationMilliseconds)
        guard trailingSilenceMilliseconds >= silenceMilliseconds else { return [] }
        candidateObserved = true
        candidate = latestPartial
        return [.candidate(candidatePresent: candidate != nil)]
    }

    public func observeFinal(_ text: String) -> [EndpointShadowOutcome] {
        let final = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let candidate = Array(candidate ?? "")
        let comparison = bucketedPrefixComparison(candidate: candidate, final: final)
        return [
            .finalComparison(
                candidatePresent: candidateObserved && !candidate.isEmpty,
                candidateMatchRatio: comparison.match,
                finalCoverageRatio: comparison.coverage
            )
        ]
    }

    public mutating func rearmAfterSpeechResumption() {
        guard candidateObserved, speechResumptionObserved else { return }
        trailingSilenceMilliseconds = 0
        candidate = nil
        candidateObserved = false
        speechResumptionObserved = false
    }
}

public actor EndpointShadowMonitor {
    private let sessionID: UUID
    private let silenceMilliseconds: Int
    private let telemetry: any TelemetryRecording
    private let maximumEvents: Int
    private let candidateHandler: (any EndpointCandidateHandling)?
    private var activeUtteranceID: UUID?
    private var evaluators = [UUID: EndpointShadowEvaluator]()
    private var candidateTimestamps = [UUID: UInt64]()
    private var retryableUtteranceIDs = Set<UUID>()
    private var events = [TelemetryEvent]()
    private var eventOverflowed = false
    private var started = false

    public init(
        sessionID: UUID,
        silenceMilliseconds: Int,
        telemetry: any TelemetryRecording,
        maximumEvents: Int = 4_096,
        candidateHandler: (any EndpointCandidateHandling)? = nil
    ) {
        self.sessionID = sessionID
        self.silenceMilliseconds = silenceMilliseconds
        self.telemetry = telemetry
        self.maximumEvents = max(1, maximumEvents)
        self.candidateHandler = candidateHandler
    }

    public func start(timestamp: UInt64) {
        guard !started else { return }
        started = true
        append(
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: nil,
                timestampNanoseconds: timestamp,
                name: .shadowEndpointEnabled,
                stage: .commit,
                metrics: .init(endpointSilenceMilliseconds: silenceMilliseconds)
            ))
    }

    public func observe(_ event: SpeechEvent, timestamp: UInt64) async {
        guard started else { return }
        await candidateHandler?.observeEndpointSpeech(event)
        switch event {
        case .speechStarted(let utteranceID):
            activeUtteranceID = utteranceID
            evaluators[utteranceID] = newEvaluator()
        case .partial(let utteranceID, let text, _):
            activeUtteranceID = utteranceID
            var evaluator = evaluators[utteranceID] ?? newEvaluator()
            evaluator.observePartial(text)
            evaluators[utteranceID] = evaluator
        case .final(let utteranceID, let text, _):
            let evaluator = evaluators.removeValue(forKey: utteranceID) ?? newEvaluator()
            record(
                evaluator.observeFinal(text),
                utteranceID: utteranceID,
                timestamp: timestamp
            )
            candidateTimestamps.removeValue(forKey: utteranceID)
            retryableUtteranceIDs.remove(utteranceID)
            if activeUtteranceID == utteranceID {
                activeUtteranceID = nil
            }
        case .speechEnded, .timing:
            break
        }
    }

    public func observeAudio(
        isSpeech: Bool,
        durationMilliseconds: Double,
        timestamp: UInt64
    ) async {
        await observeAudio(
            EndpointAudioFrame(
                isSpeech: isSpeech,
                durationMilliseconds: durationMilliseconds,
                sampleRate: 0,
                samples: []
            ),
            timestamp: timestamp
        )
    }

    public func observeAudio(_ frame: EndpointAudioFrame, timestamp: UInt64) async {
        guard started else { return }
        await candidateHandler?.observeEndpointAudio(frame)
        guard let utteranceID = activeUtteranceID,
            var evaluator = evaluators[utteranceID]
        else {
            return
        }
        let outcomes = evaluator.observeAudio(
            isSpeech: frame.isSpeech,
            durationMilliseconds: frame.durationMilliseconds
        )
        if outcomes.contains(.speechResumed), retryableUtteranceIDs.remove(utteranceID) != nil {
            evaluator.rearmAfterSpeechResumption()
        }
        evaluators[utteranceID] = evaluator
        guard !outcomes.isEmpty else { return }
        record(
            outcomes,
            utteranceID: utteranceID,
            timestamp: timestamp
        )
        let candidatePresent = outcomes.contains { outcome in
            if case .candidate(candidatePresent: true) = outcome { return true }
            return false
        }
        if candidatePresent {
            let disposition = await candidateHandler?.handleEndpointCandidate(
                utteranceID: utteranceID
            )
            if disposition == .retryAfterSpeech {
                retryableUtteranceIDs.insert(utteranceID)
            }
        }
    }

    public func stop(overflowed: Bool = false, timestamp: UInt64 = 0) async {
        await candidateHandler?.cancel()
        let shouldRecordOverflow = overflowed || eventOverflowed
        if shouldRecordOverflow {
            events.append(
                TelemetryEvent(
                    sessionID: sessionID,
                    utteranceID: nil,
                    timestampNanoseconds: timestamp,
                    name: .shadowEndpointOverflow,
                    stage: .commit,
                    metrics: .init(endpointSilenceMilliseconds: silenceMilliseconds)
                ))
        }
        let pending = events
        clear()
        for event in pending {
            _ = await telemetry.record(event)
        }
    }

    public func cancel() async {
        await candidateHandler?.cancel()
        clear()
    }

    private func newEvaluator() -> EndpointShadowEvaluator {
        EndpointShadowEvaluator(silenceMilliseconds: silenceMilliseconds)
    }

    private func record(
        _ outcomes: [EndpointShadowOutcome],
        utteranceID: UUID,
        timestamp: UInt64
    ) {
        for outcome in outcomes {
            let name: TelemetryEventName
            let metrics: TelemetryMetrics
            switch outcome {
            case .candidate(let present):
                candidateTimestamps[utteranceID] = timestamp
                name = .shadowEndpointCandidate
                metrics = .init(
                    endpointSilenceMilliseconds: silenceMilliseconds,
                    shadowCandidatePresent: present
                )
            case .speechResumed:
                name = .shadowEndpointSpeechResumed
                metrics = .init(endpointSilenceMilliseconds: silenceMilliseconds)
            case .finalComparison(let present, let match, let coverage):
                let duration = candidateTimestamps[utteranceID].map {
                    Double(timestamp - min(timestamp, $0)) / 1_000_000
                }
                name = .shadowEndpointFinalComparison
                metrics = .init(
                    durationMilliseconds: duration,
                    endpointSilenceMilliseconds: silenceMilliseconds,
                    shadowCandidatePresent: present,
                    shadowCandidateMatchRatio: match,
                    shadowFinalCoverageRatio: coverage
                )
            }
            append(
                TelemetryEvent(
                    sessionID: sessionID,
                    utteranceID: utteranceID,
                    timestampNanoseconds: timestamp,
                    name: name,
                    stage: .commit,
                    metrics: metrics
                ))
        }
    }

    private func append(_ event: TelemetryEvent) {
        guard !eventOverflowed else { return }
        guard events.count < maximumEvents else {
            eventOverflowed = true
            started = false
            return
        }
        events.append(event)
    }

    private func clear() {
        started = false
        activeUtteranceID = nil
        evaluators.removeAll()
        candidateTimestamps.removeAll()
        retryableUtteranceIDs.removeAll()
        events.removeAll()
        eventOverflowed = false
    }
}

public final class EndpointShadowQueue: @unchecked Sendable {
    private enum Input: Sendable {
        case start(timestamp: UInt64)
        case speech(SpeechEvent, timestamp: UInt64)
        case audio(EndpointAudioFrame, timestamp: UInt64)
    }

    private let continuation: AsyncStream<Input>.Continuation
    private let consumer: Task<Void, Never>
    private let monitor: EndpointShadowMonitor
    private let clock: any MonotonicClock
    private let lock = NSLock()
    private var accepting = true
    private var overflowed = false

    public init(
        monitor: EndpointShadowMonitor,
        clock: any MonotonicClock,
        bufferCapacity: Int = 256
    ) {
        self.monitor = monitor
        self.clock = clock
        let (stream, continuation) = AsyncStream.makeStream(
            of: Input.self,
            bufferingPolicy: .bufferingNewest(max(1, bufferCapacity))
        )
        self.continuation = continuation
        consumer = Task {
            for await input in stream {
                guard !Task.isCancelled else { break }
                switch input {
                case .start(let timestamp):
                    await monitor.start(timestamp: timestamp)
                case .speech(let event, let timestamp):
                    await monitor.observe(event, timestamp: timestamp)
                case .audio(let frame, let timestamp):
                    await monitor.observeAudio(frame, timestamp: timestamp)
                }
            }
        }
    }

    public func start() {
        enqueue(.start(timestamp: clock.nowNanoseconds()))
    }

    public func observe(_ event: SpeechEvent) {
        enqueue(.speech(event, timestamp: clock.nowNanoseconds()))
    }

    public func observeAudio(isSpeech: Bool, durationMilliseconds: Double) {
        observeAudio(
            EndpointAudioFrame(
                isSpeech: isSpeech,
                durationMilliseconds: durationMilliseconds,
                sampleRate: 0,
                samples: []
            ))
    }

    public func observeAudio(_ frame: EndpointAudioFrame) {
        enqueue(
            .audio(frame, timestamp: clock.nowNanoseconds())
        )
    }

    public func stop() async {
        let overflowed = finishInput()
        await consumer.value
        await monitor.stop(
            overflowed: overflowed,
            timestamp: clock.nowNanoseconds()
        )
    }

    public func cancel() async {
        _ = finishInput()
        consumer.cancel()
        await consumer.value
        await monitor.cancel()
    }

    private func enqueue(_ input: Input) {
        lock.withLock {
            guard accepting else { return }
            if case .dropped = continuation.yield(input) {
                accepting = false
                overflowed = true
                continuation.finish()
            }
        }
    }

    private func finishInput() -> Bool {
        lock.withLock {
            accepting = false
            continuation.finish()
            return overflowed
        }
    }
}
