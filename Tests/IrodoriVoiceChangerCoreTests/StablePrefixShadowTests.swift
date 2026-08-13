import Foundation
import Testing

@testable import IrodoriVoiceChangerCore

@Suite("StablePrefixShadowTests")
struct StablePrefixShadowTests {
    @Test
    func evaluatorExposesOnlyItsCurrentStableCandidateInMemory() {
        var evaluator = StablePrefixShadowEvaluator(
            minimumObservations: 2,
            minimumStableNanoseconds: 0
        )

        #expect(evaluator.candidateText == nil)
        _ = evaluator.observePartial("こん", at: 0)
        #expect(evaluator.candidateText == nil)
        _ = evaluator.observePartial("こん", at: 1)
        #expect(evaluator.candidateText == "こん")
    }

    @Test
    func monitorSubmitsOnlyFirstCandidateAndForwardsLifecycle() async {
        let recorder = ShadowMemoryRecorder()
        let handler = ShadowCandidateHandlerSpy()
        let monitor = StablePrefixShadowMonitor(
            sessionID: UUID(),
            minimumObservations: 1,
            minimumStableMilliseconds: 0,
            telemetry: recorder,
            clock: ShadowSequenceClock(values: [0, 100, 200]),
            candidateHandler: handler
        )
        let utteranceID = UUID()

        await monitor.observe(.partial(utteranceID, text: "こ", revisionCount: 0))
        await monitor.observe(.partial(utteranceID, text: "こん", revisionCount: 0))
        await monitor.observe(.final(utteranceID, text: "こんにちは", revisionCount: 0))
        await monitor.stop()
        await monitor.cancel()

        #expect(await handler.submissions == ["こ"])
        #expect(await handler.finals == ["こんにちは"])
        #expect(await handler.stopCount == 1)
        #expect(await handler.cancelCount == 1)
    }

    @Test
    func monitorRecordsOnlyShadowOutcomes() async {
        let recorder = ShadowMemoryRecorder()
        let monitor = StablePrefixShadowMonitor(
            sessionID: UUID(),
            minimumObservations: 2,
            minimumStableMilliseconds: 0,
            telemetry: recorder,
            clock: ShadowSequenceClock(values: [0, 100, 200])
        )
        let utteranceID = UUID()

        await monitor.observe(.partial(utteranceID, text: "こん", revisionCount: 0))
        await monitor.observe(.partial(utteranceID, text: "こん", revisionCount: 0))
        await monitor.observe(.final(utteranceID, text: "こんにちは", revisionCount: 0))
        await monitor.stop()

        let events = await recorder.events
        #expect(events.map(\.name) == [.shadowPrefixCandidate, .shadowFinalComparison])
        #expect(events.last?.metrics.shadowCandidatePresent == true)
        #expect(events.last?.metrics.shadowCandidateMatchRatio == 1)
        #expect(events.last?.metrics.shadowFinalCoverageRatio == 0.4)
    }

    @Test
    func monitorCancellationFlushesPendingFinalComparison() async {
        let recorder = ShadowMemoryRecorder()
        let monitor = StablePrefixShadowMonitor(
            sessionID: UUID(),
            minimumObservations: 1,
            minimumStableMilliseconds: 0,
            telemetry: recorder,
            clock: ShadowSequenceClock(values: [0, 100])
        )
        let utteranceID = UUID()

        await monitor.observe(.partial(utteranceID, text: "こん", revisionCount: 0))
        await monitor.observe(.final(utteranceID, text: "こんにちは", revisionCount: 0))
        await monitor.cancel()

        #expect(
            await recorder.events.map(\.name) == [
                .shadowPrefixCandidate, .shadowFinalComparison,
            ])
    }

    @Test
    func candidateRequiresBothObservationAndDurationThresholds() {
        var evaluator = StablePrefixShadowEvaluator(
            minimumObservations: 2,
            minimumStableNanoseconds: 100
        )

        #expect(evaluator.observePartial("こん", at: 0).isEmpty)
        #expect(evaluator.observePartial("こん", at: 50).isEmpty)
        #expect(evaluator.observePartial("こん", at: 100) == [.candidateAdvanced])
    }

    @Test
    func appendOnlyPartialCanAdvanceCandidateWithoutRewrite() {
        var evaluator = StablePrefixShadowEvaluator(
            minimumObservations: 2,
            minimumStableNanoseconds: 100
        )

        _ = evaluator.observePartial("こん", at: 0)
        #expect(evaluator.observePartial("こんに", at: 100) == [.candidateAdvanced])
        #expect(evaluator.observePartial("こんにちは", at: 200) == [.candidateAdvanced])
    }

    @Test
    func rewriteAfterCandidateDoesNotRollbackUnchangedCandidate() {
        var evaluator = StablePrefixShadowEvaluator(
            minimumObservations: 2,
            minimumStableNanoseconds: 100
        )

        _ = evaluator.observePartial("こん", at: 0)
        _ = evaluator.observePartial("こんに", at: 100)
        #expect(evaluator.observePartial("こんば", at: 200) == [.rewrite])
    }

    @Test
    func rewriteInsideCandidateRecordsRollback() {
        var evaluator = StablePrefixShadowEvaluator(
            minimumObservations: 2,
            minimumStableNanoseconds: 100
        )

        _ = evaluator.observePartial("こん", at: 0)
        _ = evaluator.observePartial("こん", at: 100)

        #expect(evaluator.observePartial("こば", at: 200) == [.rewrite, .rollback])
    }

    @Test
    func finalComparisonContainsOnlyBoundedRatios() {
        var evaluator = StablePrefixShadowEvaluator(
            minimumObservations: 2,
            minimumStableNanoseconds: 100
        )

        _ = evaluator.observePartial("こん", at: 0)
        _ = evaluator.observePartial("こん", at: 100)

        #expect(
            evaluator.observeFinal("こんにちは")
                == [
                    .finalComparison(
                        candidatePresent: true,
                        candidateMatchRatio: 1,
                        finalCoverageRatio: 0.4
                    )
                ])
    }

    @Test
    func comparisonRatiosAreBucketedToAvoidLeakingExactTextLengths() {
        var evaluator = StablePrefixShadowEvaluator(
            minimumObservations: 2,
            minimumStableNanoseconds: 100
        )

        _ = evaluator.observePartial("こん", at: 0)
        _ = evaluator.observePartial("こん", at: 100)

        #expect(
            evaluator.observeFinal("こんに")
                == [
                    .finalComparison(
                        candidatePresent: true,
                        candidateMatchRatio: 1,
                        finalCoverageRatio: 0.7
                    )
                ])
    }

    @Test
    func finalRewriteInsideCandidateRecordsRollbackBeforeComparison() {
        var evaluator = StablePrefixShadowEvaluator(
            minimumObservations: 2,
            minimumStableNanoseconds: 100
        )

        _ = evaluator.observePartial("こん", at: 0)
        _ = evaluator.observePartial("こん", at: 100)

        #expect(
            evaluator.observeFinal("こば")
                == [
                    .rollback,
                    .finalComparison(
                        candidatePresent: true,
                        candidateMatchRatio: 0.5,
                        finalCoverageRatio: 0.5
                    ),
                ])
    }
}

private actor ShadowMemoryRecorder: TelemetryRecording {
    private(set) var events = [TelemetryEvent]()

    func record(_ event: TelemetryEvent) -> TelemetryWriteResult {
        events.append(event)
        return .written
    }
}

private actor ShadowCandidateHandlerSpy: StablePrefixCandidateHandling {
    private(set) var submissions = [String]()
    private(set) var finals = [String]()
    private(set) var stopCount = 0
    private(set) var cancelCount = 0

    func submit(candidate: String, utteranceID _: UUID) {
        submissions.append(candidate)
    }

    func finish(final: String, utteranceID _: UUID) {
        finals.append(final)
    }

    func stop() {
        stopCount += 1
    }

    func cancel() {
        cancelCount += 1
    }
}

private struct ShadowSequenceClock: MonotonicClock {
    private let state: ShadowClockState

    init(values: [UInt64]) {
        state = ShadowClockState(values: values)
    }

    func nowNanoseconds() -> UInt64 {
        state.next()
    }
}

private final class ShadowClockState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64 {
        lock.withLock {
            values.isEmpty ? 0 : values.removeFirst()
        }
    }
}
