import Foundation
import Testing

@testable import IrodoriVoiceChangerCore

@Suite("EndpointShadowTests")
struct EndpointShadowTests {
    @Test
    func monitorStartRecordsEnabledThresholdWithoutSpeech() async {
        let recorder = EndpointMemoryRecorder()
        let monitor = EndpointShadowMonitor(
            sessionID: UUID(),
            silenceMilliseconds: 1_200,
            telemetry: recorder
        )

        await monitor.start(timestamp: 100)
        await monitor.stop()

        let event = await recorder.events.first
        #expect(event?.name == .shadowEndpointEnabled)
        #expect(event?.utteranceID == nil)
        #expect(event?.metrics.endpointSilenceMilliseconds == 1_200)
    }

    @Test
    func firstThresholdCrossingSnapshotsLatestPartial() {
        var evaluator = EndpointShadowEvaluator(silenceMilliseconds: 300)
        evaluator.observePartial("こんにちは")

        #expect(evaluator.observeAudio(isSpeech: true, durationMilliseconds: 100).isEmpty)
        #expect(evaluator.observeAudio(isSpeech: false, durationMilliseconds: 200).isEmpty)
        #expect(
            evaluator.observeAudio(isSpeech: false, durationMilliseconds: 100)
                == [.candidate(candidatePresent: true)])
        evaluator.observePartial("こんにちは世界")

        #expect(
            evaluator.observeFinal("こんにちは世界")
                == [
                    .finalComparison(
                        candidatePresent: true,
                        candidateMatchRatio: 1,
                        finalCoverageRatio: 0.7
                    )
                ])
    }

    @Test
    func thresholdWithoutPartialRecordsMissingCandidate() {
        var evaluator = EndpointShadowEvaluator(silenceMilliseconds: 300)

        #expect(
            evaluator.observeAudio(isSpeech: false, durationMilliseconds: 300)
                == [.candidate(candidatePresent: false)])
        evaluator.observePartial("遅れて届いたpartial")

        #expect(
            evaluator.observeFinal("遅れて届いたpartial")
                == [
                    .finalComparison(
                        candidatePresent: false,
                        candidateMatchRatio: 0,
                        finalCoverageRatio: 0
                    )
                ])
    }

    @Test
    func speechBeforeThresholdResetsTrailingSilence() {
        var evaluator = EndpointShadowEvaluator(silenceMilliseconds: 300)
        evaluator.observePartial("途中")

        _ = evaluator.observeAudio(isSpeech: false, durationMilliseconds: 200)
        _ = evaluator.observeAudio(isSpeech: true, durationMilliseconds: 50)

        #expect(evaluator.observeAudio(isSpeech: false, durationMilliseconds: 200).isEmpty)
        #expect(
            evaluator.observeAudio(isSpeech: false, durationMilliseconds: 100)
                == [.candidate(candidatePresent: true)])
    }

    @Test
    func speechAfterCandidateRecordsOneResumption() {
        var evaluator = EndpointShadowEvaluator(silenceMilliseconds: 300)
        evaluator.observePartial("早すぎる境界")
        _ = evaluator.observeAudio(isSpeech: false, durationMilliseconds: 300)

        #expect(
            evaluator.observeAudio(isSpeech: true, durationMilliseconds: 50)
                == [.speechResumed])
        #expect(evaluator.observeAudio(isSpeech: true, durationMilliseconds: 50).isEmpty)
        #expect(evaluator.observeAudio(isSpeech: false, durationMilliseconds: 300).isEmpty)
    }

    @Test
    func retryableCandidateRearmsOnlyAfterSpeechResumes() async {
        let handler = EndpointCandidateHandlerSpy(disposition: .retryAfterSpeech)
        let monitor = EndpointShadowMonitor(
            sessionID: UUID(),
            silenceMilliseconds: 300,
            telemetry: EndpointMemoryRecorder(),
            candidateHandler: handler
        )
        let utteranceID = UUID()

        await monitor.start(timestamp: 1)
        await monitor.observe(.speechStarted(utteranceID), timestamp: 2)
        await monitor.observe(
            .partial(utteranceID, text: "候補", revisionCount: 0),
            timestamp: 3
        )
        await monitor.observeAudio(
            isSpeech: false,
            durationMilliseconds: 300,
            timestamp: 4
        )
        await monitor.observeAudio(
            isSpeech: false,
            durationMilliseconds: 300,
            timestamp: 5
        )
        await monitor.observeAudio(
            isSpeech: true,
            durationMilliseconds: 50,
            timestamp: 6
        )
        await monitor.observeAudio(
            isSpeech: false,
            durationMilliseconds: 300,
            timestamp: 7
        )

        #expect(await handler.utteranceIDs == [utteranceID, utteranceID])
    }

    @Test
    func separateEvaluatorStartsWithoutPriorCandidateState() {
        var first = EndpointShadowEvaluator(silenceMilliseconds: 300)
        first.observePartial("一回目")
        _ = first.observeAudio(isSpeech: false, durationMilliseconds: 300)
        _ = first.observeFinal("一回目")

        var second = EndpointShadowEvaluator(silenceMilliseconds: 300)
        second.observePartial("二回目")

        #expect(
            second.observeAudio(isSpeech: false, durationMilliseconds: 300)
                == [.candidate(candidatePresent: true)])
    }

    @Test
    func monitorRecordsContentFreeCandidateResumptionAndFinalComparison() async {
        let recorder = EndpointMemoryRecorder()
        let monitor = EndpointShadowMonitor(
            sessionID: UUID(),
            silenceMilliseconds: 300,
            telemetry: recorder
        )
        let queue = EndpointShadowQueue(
            monitor: monitor,
            clock: EndpointSequenceClock(
                values: [1, 2, 3, 100_000_000, 200_000_000, 900_000_000])
        )
        let utteranceID = UUID()

        queue.start()
        queue.observe(.speechStarted(utteranceID))
        queue.observe(.partial(utteranceID, text: "候補", revisionCount: 0))
        queue.observeAudio(isSpeech: false, durationMilliseconds: 300)
        queue.observeAudio(isSpeech: true, durationMilliseconds: 50)
        queue.observe(.final(utteranceID, text: "候補です", revisionCount: 0))
        await queue.stop()

        let events = await recorder.events
        #expect(
            events.map(\.name)
                == [
                    .shadowEndpointEnabled,
                    .shadowEndpointCandidate,
                    .shadowEndpointSpeechResumed,
                    .shadowEndpointFinalComparison,
                ])
        #expect(events[1].metrics.endpointSilenceMilliseconds == 300)
        #expect(events[1].metrics.shadowCandidatePresent == true)
        #expect(events[3].metrics.durationMilliseconds == 800)
        #expect(events[3].metrics.shadowCandidateMatchRatio == 1)
        #expect(events[3].metrics.shadowFinalCoverageRatio == 0.5)

        await monitor.cancel()
    }

    @Test
    func queuedShadowInputDoesNotWaitForBlockedTelemetry() async {
        let recorder = BlockingEndpointRecorder()
        let monitor = EndpointShadowMonitor(
            sessionID: UUID(),
            silenceMilliseconds: 300,
            telemetry: recorder
        )
        let queue = EndpointShadowQueue(
            monitor: monitor,
            clock: EndpointSequenceClock(
                values: [100, 200, 300, 1_000_000_000, 2_000_000_000, 3_000_000_000])
        )
        let utteranceID = UUID()

        queue.start()
        queue.observe(.speechStarted(utteranceID))
        queue.observe(.partial(utteranceID, text: "候補", revisionCount: 0))
        queue.observeAudio(isSpeech: false, durationMilliseconds: 300)
        queue.observe(.final(utteranceID, text: "候補です", revisionCount: 0))

        #expect(await recorder.recordAttemptCount == 0)
        let stop = Task { await queue.stop() }
        await recorder.waitUntilBlocked()
        #expect(await recorder.recordAttemptCount == 1)
        await recorder.release()
        await stop.value

        #expect(
            await recorder.events.map(\.name)
                == [
                    .shadowEndpointEnabled,
                    .shadowEndpointCandidate,
                    .shadowEndpointFinalComparison,
                ])
        #expect(await recorder.events.last?.metrics.durationMilliseconds == 1_000)
    }

    @Test
    func cancelledMonitorIgnoresLateSpeechAndActivity() async {
        let recorder = EndpointMemoryRecorder()
        let monitor = EndpointShadowMonitor(
            sessionID: UUID(),
            silenceMilliseconds: 300,
            telemetry: recorder
        )
        let utteranceID = UUID()

        await monitor.start(timestamp: 100)
        await monitor.cancel()
        await monitor.observe(.speechStarted(utteranceID), timestamp: 200)
        await monitor.observe(
            .partial(utteranceID, text: "停止後", revisionCount: 0),
            timestamp: 300
        )
        await monitor.observeAudio(
            isSpeech: false,
            durationMilliseconds: 300,
            timestamp: 400
        )
        await monitor.observe(
            .final(utteranceID, text: "停止後", revisionCount: 0),
            timestamp: 500
        )

        #expect(await recorder.events.isEmpty)
    }

    @Test
    func boundedQueueFailsClosedAndRecordsOverflow() async {
        let recorder = EndpointMemoryRecorder()
        let monitor = EndpointShadowMonitor(
            sessionID: UUID(),
            silenceMilliseconds: 300,
            telemetry: recorder
        )
        let queue = EndpointShadowQueue(
            monitor: monitor,
            clock: EndpointSequenceClock(values: Array(1...100).map(UInt64.init)),
            bufferCapacity: 1
        )

        queue.start()
        for _ in 0..<20 {
            queue.observeAudio(isSpeech: false, durationMilliseconds: 50)
        }
        await queue.stop()

        #expect(await recorder.events.contains { $0.name == .shadowEndpointOverflow })
    }

    @Test
    func boundedEventBufferFailsClosedAndRecordsOverflow() async {
        let recorder = EndpointMemoryRecorder()
        let monitor = EndpointShadowMonitor(
            sessionID: UUID(),
            silenceMilliseconds: 300,
            telemetry: recorder,
            maximumEvents: 1
        )
        let utteranceID = UUID()

        await monitor.start(timestamp: 1)
        await monitor.observe(.speechStarted(utteranceID), timestamp: 2)
        await monitor.observe(
            .partial(utteranceID, text: "候補", revisionCount: 0),
            timestamp: 3
        )
        await monitor.observeAudio(
            isSpeech: false,
            durationMilliseconds: 300,
            timestamp: 4
        )
        await monitor.stop(timestamp: 5)

        #expect(
            await recorder.events.map(\.name)
                == [.shadowEndpointEnabled, .shadowEndpointOverflow])
    }

    @Test
    func candidateWithPartialInvokesHandlerOnce() async {
        let handler = EndpointCandidateHandlerSpy()
        let monitor = EndpointShadowMonitor(
            sessionID: UUID(),
            silenceMilliseconds: 300,
            telemetry: EndpointMemoryRecorder(),
            candidateHandler: handler
        )
        let utteranceID = UUID()

        await monitor.start(timestamp: 1)
        await monitor.observe(.speechStarted(utteranceID), timestamp: 2)
        await monitor.observe(
            .partial(utteranceID, text: "候補", revisionCount: 0),
            timestamp: 3
        )
        await monitor.observeAudio(
            isSpeech: false,
            durationMilliseconds: 300,
            timestamp: 4
        )
        await monitor.observeAudio(
            isSpeech: false,
            durationMilliseconds: 300,
            timestamp: 5
        )

        #expect(await handler.utteranceIDs == [utteranceID])
    }

    @Test
    func candidateWithoutPartialDoesNotInvokeHandler() async {
        let handler = EndpointCandidateHandlerSpy()
        let monitor = EndpointShadowMonitor(
            sessionID: UUID(),
            silenceMilliseconds: 300,
            telemetry: EndpointMemoryRecorder(),
            candidateHandler: handler
        )
        let utteranceID = UUID()

        await monitor.start(timestamp: 1)
        await monitor.observe(.speechStarted(utteranceID), timestamp: 2)
        await monitor.observeAudio(
            isSpeech: false,
            durationMilliseconds: 300,
            timestamp: 3
        )

        #expect(await handler.utteranceIDs.isEmpty)
    }
}

private actor EndpointCandidateHandlerSpy: EndpointCandidateHandling {
    private(set) var utteranceIDs = [UUID]()
    private let disposition: EndpointCandidateDisposition

    init(disposition: EndpointCandidateDisposition = .terminal) {
        self.disposition = disposition
    }

    func handleEndpointCandidate(utteranceID: UUID) -> EndpointCandidateDisposition {
        utteranceIDs.append(utteranceID)
        return disposition
    }
}

private actor EndpointMemoryRecorder: TelemetryRecording {
    private(set) var events = [TelemetryEvent]()

    func record(_ event: TelemetryEvent) -> TelemetryWriteResult {
        events.append(event)
        return .written
    }
}

private actor BlockingEndpointRecorder: TelemetryRecording {
    private(set) var events = [TelemetryEvent]()
    private(set) var recordAttemptCount = 0
    private var blockedWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()
    private var released = false

    func record(_ event: TelemetryEvent) async -> TelemetryWriteResult {
        recordAttemptCount += 1
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        events.append(event)
        return .written
    }

    func waitUntilBlocked() async {
        guard recordAttemptCount == 0 else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private struct EndpointSequenceClock: MonotonicClock {
    private let state: EndpointClockState

    init(values: [UInt64]) {
        state = EndpointClockState(values: values)
    }

    func nowNanoseconds() -> UInt64 {
        state.next()
    }
}

private final class EndpointClockState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64 {
        lock.withLock { values.isEmpty ? 0 : values.removeFirst() }
    }
}
