import Foundation
import Testing

@testable import IrodoriVoiceChangerCore

@Suite("SemanticEndpointTests")
struct SemanticEndpointTests {
    @Test
    func incompleteDecisionRequestsRetryAfterSpeech() async throws {
        let classifier = SemanticClassifierSpy(
            prediction: try SemanticTurnPrediction(probability: 0.1, durationMilliseconds: 12)
        )
        let handler = SemanticEndpointHandler(
            sessionID: UUID(),
            classifier: classifier,
            telemetry: SemanticMemoryRecorder(),
            clock: SemanticSequenceClock(values: [10, 20])
        )
        let utteranceID = UUID()

        await handler.observeEndpointAudio(
            EndpointAudioFrame(
                isSpeech: false,
                durationMilliseconds: 100,
                sampleRate: 16_000,
                samples: [0.1, 0.2]
            )
        )
        let disposition = await handler.handleEndpointCandidate(utteranceID: utteranceID)

        #expect(disposition == .retryAfterSpeech)
        #expect(await classifier.sampleCounts == [2])
    }

    @Test
    func completeDecisionRemainsNonTerminalInShadowMode() async throws {
        let classifier = SemanticClassifierSpy(
            prediction: try SemanticTurnPrediction(probability: 0.9, durationMilliseconds: 8)
        )
        let handler = SemanticEndpointHandler(
            sessionID: UUID(),
            classifier: classifier,
            telemetry: SemanticMemoryRecorder(),
            clock: SemanticSequenceClock(values: [10, 20])
        )

        let disposition = await handler.handleEndpointCandidate(utteranceID: UUID())

        #expect(disposition == .retryAfterSpeech)
    }

    @Test
    func audioBufferKeepsOnlyLatestEightSeconds() async throws {
        let classifier = SemanticClassifierSpy(
            prediction: try SemanticTurnPrediction(probability: 0.1, durationMilliseconds: 4)
        )
        let handler = SemanticEndpointHandler(
            sessionID: UUID(),
            classifier: classifier,
            telemetry: SemanticMemoryRecorder(),
            clock: SemanticSequenceClock(values: [10, 20])
        )

        await handler.observeEndpointAudio(
            EndpointAudioFrame(
                isSpeech: true,
                durationMilliseconds: 9_000,
                sampleRate: 10,
                samples: Array(repeating: 0.1, count: 90)
            )
        )
        _ = await handler.handleEndpointCandidate(utteranceID: UUID())

        #expect(await classifier.sampleCounts == [80])
        #expect(await classifier.sampleRates == [10])
    }

    @Test
    func finalAndCancelClearBufferedAudio() async throws {
        let classifier = SemanticClassifierSpy(
            prediction: try SemanticTurnPrediction(probability: 0.1, durationMilliseconds: 4)
        )
        let handler = SemanticEndpointHandler(
            sessionID: UUID(),
            classifier: classifier,
            telemetry: SemanticMemoryRecorder(),
            clock: SemanticSequenceClock(values: [10, 20, 30, 40])
        )
        let utteranceID = UUID()
        let frame = EndpointAudioFrame(
            isSpeech: true,
            durationMilliseconds: 100,
            sampleRate: 16_000,
            samples: [0.1, 0.2]
        )

        await handler.observeEndpointAudio(frame)
        await handler.observeEndpointSpeech(.final(utteranceID, text: "完了", revisionCount: 0))
        _ = await handler.handleEndpointCandidate(utteranceID: utteranceID)
        await handler.observeEndpointAudio(frame)
        await handler.cancel()
        _ = await handler.handleEndpointCandidate(utteranceID: utteranceID)

        #expect(await classifier.sampleCounts == [0, 0])
    }

    @Test
    func speechStartedPreservesAudioAlreadyDeliveredByTheInputQueue() async throws {
        let classifier = SemanticClassifierSpy(
            prediction: try SemanticTurnPrediction(probability: 0.1, durationMilliseconds: 4)
        )
        let handler = SemanticEndpointHandler(
            sessionID: UUID(),
            classifier: classifier,
            telemetry: SemanticMemoryRecorder(),
            clock: SemanticSequenceClock(values: [10, 20])
        )
        let utteranceID = UUID()

        await handler.observeEndpointAudio(
            EndpointAudioFrame(
                isSpeech: true,
                durationMilliseconds: 100,
                sampleRate: 16_000,
                samples: [0.1, 0.2]
            )
        )
        await handler.observeEndpointSpeech(.speechStarted(utteranceID))
        _ = await handler.handleEndpointCandidate(utteranceID: utteranceID)

        #expect(await classifier.sampleCounts == [2])
    }

}

private actor SemanticClassifierSpy: SemanticTurnClassifying {
    private let prediction: SemanticTurnPrediction
    private(set) var sampleCounts = [Int]()
    private(set) var sampleRates = [Double]()

    init(prediction: SemanticTurnPrediction) {
        self.prediction = prediction
    }

    func predict(samples: [Float], sampleRate: Double) -> SemanticTurnPrediction {
        sampleCounts.append(samples.count)
        sampleRates.append(sampleRate)
        return prediction
    }
}

private actor SemanticMemoryRecorder: TelemetryRecording {
    private(set) var events = [TelemetryEvent]()

    func record(_ event: TelemetryEvent) -> TelemetryWriteResult {
        events.append(event)
        return .written
    }
}

private struct SemanticSequenceClock: MonotonicClock {
    private let state: SemanticClockState

    init(values: [UInt64]) {
        state = SemanticClockState(values: values)
    }

    func nowNanoseconds() -> UInt64 {
        state.next()
    }
}

private final class SemanticClockState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64 {
        lock.withLock { values.isEmpty ? 0 : values.removeFirst() }
    }
}
