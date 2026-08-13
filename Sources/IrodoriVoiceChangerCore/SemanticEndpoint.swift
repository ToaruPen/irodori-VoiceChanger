import Foundation

public enum SemanticTurnPredictionError: Error, Equatable, Sendable {
    case invalidProbability
    case invalidDuration
}

public struct SemanticTurnPrediction: Equatable, Sendable {
    public let probability: Double
    public let durationMilliseconds: Double

    public init(probability: Double, durationMilliseconds: Double) throws {
        guard probability.isFinite, (0...1).contains(probability) else {
            throw SemanticTurnPredictionError.invalidProbability
        }
        guard durationMilliseconds.isFinite, durationMilliseconds >= 0 else {
            throw SemanticTurnPredictionError.invalidDuration
        }
        self.probability = probability
        self.durationMilliseconds = durationMilliseconds
    }

    public var isComplete: Bool { probability > 0.5 }
}

public protocol SemanticTurnClassifying: Sendable {
    func predict(samples: [Float], sampleRate: Double) async throws -> SemanticTurnPrediction
}

public actor SemanticEndpointHandler: EndpointCandidateHandling {
    private let sessionID: UUID
    private let classifier: any SemanticTurnClassifying
    private let telemetry: any TelemetryRecording
    private let clock: any MonotonicClock
    private var samples = [Float]()
    private var sampleRate = 16_000.0
    private var activeUtteranceID: UUID?
    private var failure: StableErrorCode?

    public init(
        sessionID: UUID,
        classifier: any SemanticTurnClassifying,
        telemetry: any TelemetryRecording,
        clock: any MonotonicClock
    ) {
        self.sessionID = sessionID
        self.classifier = classifier
        self.telemetry = telemetry
        self.clock = clock
    }

    public func observeEndpointSpeech(_ event: SpeechEvent) async {
        switch event {
        case .speechStarted(let utteranceID):
            if let activeUtteranceID, activeUtteranceID != utteranceID {
                clearAudio()
            }
            activeUtteranceID = utteranceID
        case .final(let utteranceID, _, _):
            clearAudio()
            if activeUtteranceID == utteranceID {
                activeUtteranceID = nil
            }
        case .partial, .speechEnded, .timing:
            break
        }
    }

    public func observeEndpointAudio(_ frame: EndpointAudioFrame) async {
        guard frame.sampleRate.isFinite, frame.sampleRate > 0 else { return }
        if sampleRate != frame.sampleRate {
            samples.removeAll(keepingCapacity: true)
            sampleRate = frame.sampleRate
        }
        samples.append(contentsOf: frame.samples)
        let maximumSamples = max(1, Int(sampleRate * 8))
        if samples.count > maximumSamples {
            samples.removeFirst(samples.count - maximumSamples)
        }
    }

    public func handleEndpointCandidate(
        utteranceID: UUID
    ) async -> EndpointCandidateDisposition {
        guard failure == nil else { return .terminal }
        let snapshot = samples
        let snapshotSampleRate = sampleRate
        let started = clock.nowNanoseconds()
        await record(.semanticEndpointRequested, utteranceID: utteranceID, timestamp: started)
        do {
            let prediction = try await classifier.predict(
                samples: snapshot,
                sampleRate: snapshotSampleRate
            )
            await record(
                .semanticEndpointCompleted,
                utteranceID: utteranceID,
                timestamp: clock.nowNanoseconds(),
                durationMilliseconds: prediction.durationMilliseconds,
                probabilityBucket: probabilityBucket(prediction.probability),
                complete: prediction.isComplete
            )
            return .retryAfterSpeech
        } catch {
            failure = .speechUnavailable
            let completed = clock.nowNanoseconds()
            await record(
                .semanticEndpointFailed,
                utteranceID: utteranceID,
                timestamp: completed,
                durationMilliseconds: elapsedMilliseconds(from: started, to: completed),
                errorCode: .speechUnavailable
            )
            return .terminal
        }
    }

    public func cancel() async {
        clearAudio()
        activeUtteranceID = nil
    }

    public func failureRequiringStop() -> StableErrorCode? {
        failure
    }

    private func clearAudio() {
        samples.removeAll(keepingCapacity: true)
    }

    private func probabilityBucket(_ probability: Double) -> Int {
        min(3, max(0, Int(probability * 4)))
    }

    private func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - min(start, end)) / 1_000_000
    }

    private func record(
        _ name: TelemetryEventName,
        utteranceID: UUID,
        timestamp: UInt64,
        durationMilliseconds: Double? = nil,
        probabilityBucket: Int? = nil,
        complete: Bool? = nil,
        errorCode: StableErrorCode? = nil
    ) async {
        _ = await telemetry.record(
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: utteranceID,
                timestampNanoseconds: timestamp,
                name: name,
                stage: .speech,
                errorCode: errorCode,
                metrics: .init(
                    durationMilliseconds: durationMilliseconds,
                    semanticProbabilityBucket: probabilityBucket,
                    semanticTurnComplete: complete
                )
            )
        )
    }
}
