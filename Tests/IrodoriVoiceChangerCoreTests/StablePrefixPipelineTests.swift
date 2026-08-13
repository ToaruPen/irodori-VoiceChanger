import Foundation
import Testing

@testable import IrodoriVoiceChangerCore

@Suite("StablePrefixPipelineTests")
struct StablePrefixPipelineTests {
    @Test
    func candidateFinishesBeforeFinalSynthesisAndPipelineStopsHandler() async {
        let order = ShadowOperationOrder()
        let handler = ShadowPipelineCandidateHandler(order: order)
        let recorder = ShadowPipelineRecorder()
        let player = ShadowCountingPlayer()
        let monitor = StablePrefixShadowMonitor(
            sessionID: UUID(),
            minimumObservations: 1,
            minimumStableMilliseconds: 0,
            telemetry: recorder,
            clock: SystemMonotonicClock(),
            candidateHandler: handler
        )
        let pipeline = VoiceChangerPipeline(
            synthesizer: ShadowOrderedSynthesizer(order: order),
            player: player,
            telemetry: recorder,
            clock: SystemMonotonicClock(),
            maximumPendingSynthesis: 2,
            maximumPendingPlayback: 2,
            shadowMonitor: monitor
        )
        let utteranceID = UUID()

        await pipeline.handle(.partial(utteranceID, text: "こ", revisionCount: 0))
        await pipeline.handle(.final(utteranceID, text: "こんにちは", revisionCount: 0))
        await pipeline.stop()

        #expect(
            await order.values == [
                "candidate_submit", "candidate_finish", "final_synthesis", "candidate_stop",
            ])
        #expect(await player.playCount == 1)
    }

    @Test
    func candidateFinishesBeforeFinalComparisonTelemetry() async {
        let order = ShadowOperationOrder()
        let recorder = ShadowBlockingFinalRecorder(order: order)
        let monitor = StablePrefixShadowMonitor(
            sessionID: UUID(),
            minimumObservations: 1,
            minimumStableMilliseconds: 0,
            telemetry: recorder,
            clock: SystemMonotonicClock(),
            candidateHandler: ShadowPipelineCandidateHandler(order: order)
        )
        let pipeline = VoiceChangerPipeline(
            synthesizer: ShadowOrderedSynthesizer(order: order),
            player: ShadowPipelinePlayer(),
            telemetry: recorder,
            clock: SystemMonotonicClock(),
            maximumPendingSynthesis: 1,
            maximumPendingPlayback: 1,
            shadowMonitor: monitor
        )
        let utteranceID = UUID()

        await pipeline.handle(.partial(utteranceID, text: "こ", revisionCount: 0))
        let final = Task {
            await pipeline.handle(.final(utteranceID, text: "こんにちは", revisionCount: 0))
        }
        for _ in 0..<100 where !(await order.values.contains("final_synthesis")) {
            await Task.yield()
        }

        #expect(
            await order.values.starts(with: [
                "candidate_submit", "candidate_finish", "final_synthesis",
            ]))

        await recorder.release()
        await final.value
        await pipeline.stop()
    }

    @Test
    func pipelineCancellationCancelsCandidateHandler() async {
        let handler = ShadowPipelineCandidateHandler(order: ShadowOperationOrder())
        let monitor = StablePrefixShadowMonitor(
            sessionID: UUID(),
            minimumObservations: 1,
            minimumStableMilliseconds: 0,
            telemetry: ShadowPipelineRecorder(),
            clock: SystemMonotonicClock(),
            candidateHandler: handler
        )
        let pipeline = VoiceChangerPipeline(
            synthesizer: ShadowPipelineSynthesizer(),
            player: ShadowPipelinePlayer(),
            telemetry: ShadowPipelineRecorder(),
            clock: SystemMonotonicClock(),
            maximumPendingSynthesis: 1,
            maximumPendingPlayback: 1,
            shadowMonitor: monitor
        )

        await pipeline.cancel()

        #expect(await handler.cancelCount == 1)
    }

    @Test
    func shadowCandidateNeverSynthesizesBeforeFinal() async {
        let recorder = ShadowPipelineRecorder()
        let synthesizer = ShadowPipelineSynthesizer()
        let clock = SystemMonotonicClock()
        let monitor = StablePrefixShadowMonitor(
            sessionID: UUID(),
            minimumObservations: 2,
            minimumStableMilliseconds: 0,
            telemetry: recorder,
            clock: clock
        )
        let pipeline = VoiceChangerPipeline(
            synthesizer: synthesizer,
            player: ShadowPipelinePlayer(),
            telemetry: recorder,
            clock: clock,
            maximumPendingSynthesis: 2,
            maximumPendingPlayback: 2,
            shadowMonitor: monitor
        )
        let utteranceID = UUID()

        await pipeline.handle(.partial(utteranceID, text: "こん", revisionCount: 0))
        await pipeline.handle(.partial(utteranceID, text: "こん", revisionCount: 0))

        #expect(await synthesizer.texts.isEmpty)
        #expect(await recorder.events.filter { $0.name == .requestStarted }.isEmpty)
        #expect(await recorder.events.filter { $0.name == .shadowPrefixCandidate }.count == 1)

        await pipeline.handle(.final(utteranceID, text: "こんにちは", revisionCount: 0))
        await pipeline.waitUntilIdle()

        #expect(await synthesizer.texts == ["こんにちは"])
        #expect(await recorder.events.filter { $0.name == .requestStarted }.count == 1)
    }
}

private actor ShadowPipelineRecorder: TelemetryRecording {
    private(set) var events = [TelemetryEvent]()

    func record(_ event: TelemetryEvent) -> TelemetryWriteResult {
        events.append(event)
        return .written
    }
}

private actor ShadowBlockingFinalRecorder: TelemetryRecording {
    private let order: ShadowOperationOrder
    private var released = false
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()

    init(order: ShadowOperationOrder) {
        self.order = order
    }

    func record(_ event: TelemetryEvent) async -> TelemetryWriteResult {
        if event.name == .shadowFinalComparison {
            await order.append("shadow_final_comparison")
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
        }
        return .written
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor ShadowPipelineSynthesizer: Synthesizing {
    private(set) var texts = [String]()

    func synthesize(
        text: String,
        utteranceID _: UUID,
        onMilestone: @Sendable (SynthesisMilestone) async -> Void
    ) async throws -> AudioClip {
        texts.append(text)
        await onMilestone(.completed(serverElapsedMilliseconds: 1, samplingSteps: 12))
        return AudioClip(wavBytes: Data(), durationMilliseconds: 1)
    }
}

private actor ShadowPipelinePlayer: AudioPlaying {
    func play(_: AudioClip, utteranceID _: UUID) async throws {}
}

private actor ShadowOperationOrder {
    private(set) var values = [String]()

    func append(_ value: String) {
        values.append(value)
    }
}

private actor ShadowPipelineCandidateHandler: StablePrefixCandidateHandling {
    private let order: ShadowOperationOrder
    private(set) var cancelCount = 0

    init(order: ShadowOperationOrder) {
        self.order = order
    }

    func submit(candidate _: String, utteranceID _: UUID) async {
        await order.append("candidate_submit")
    }

    func finish(final _: String, utteranceID _: UUID) async {
        await order.append("candidate_finish")
    }

    func stop() async {
        await order.append("candidate_stop")
    }

    func cancel() {
        cancelCount += 1
    }
}

private actor ShadowOrderedSynthesizer: Synthesizing {
    private let order: ShadowOperationOrder

    init(order: ShadowOperationOrder) {
        self.order = order
    }

    func synthesize(
        text _: String,
        utteranceID _: UUID,
        onMilestone: @Sendable (SynthesisMilestone) async -> Void
    ) async throws -> AudioClip {
        await order.append("final_synthesis")
        await onMilestone(.completed(serverElapsedMilliseconds: 1, samplingSteps: 12))
        return AudioClip(wavBytes: Data(), durationMilliseconds: 1)
    }
}

private actor ShadowCountingPlayer: AudioPlaying {
    private(set) var playCount = 0

    func play(_: AudioClip, utteranceID _: UUID) {
        playCount += 1
    }
}
