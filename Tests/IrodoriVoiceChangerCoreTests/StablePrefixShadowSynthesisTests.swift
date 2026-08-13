import Foundation
import Testing

@testable import IrodoriVoiceChangerCore

@Suite("StablePrefixShadowSynthesisTests")
struct StablePrefixShadowSynthesisTests {
    @Test
    func firstCandidateSynthesizesOnceAndAudioIsOnlyMeasured() async throws {
        let recorder = CandidateMemoryRecorder()
        let synthesizer = CandidateRecordingSynthesizer()
        let subject = DiscardingStablePrefixSynthesizer(
            sessionID: UUID(),
            synthesizer: synthesizer,
            telemetry: recorder,
            clock: SystemMonotonicClock()
        )
        let utteranceID = UUID()

        await subject.submit(candidate: "こん", utteranceID: utteranceID)
        await subject.submit(candidate: "こんにちは", utteranceID: utteranceID)
        await subject.stop()

        #expect(await synthesizer.texts == ["こん"])
        let events = await recorder.events
        #expect(
            events.map(\.name) == [
                .shadowSynthesisStarted,
                .shadowSynthesisHandshake,
                .shadowSynthesisFirstAudio,
                .shadowSynthesisCompleted,
            ])
        #expect(events.last?.metrics.audioDurationMilliseconds == 12)
        #expect(events.last?.metrics.byteCount == 3)
        #expect(!events.contains { $0.name == .playbackEnqueued })
        #expect(!events.contains { $0.name == .requestStarted })
    }

    @Test
    func finalCancelsUnfinishedCandidateWithoutThrowing() async {
        let recorder = CandidateMemoryRecorder()
        let synthesizer = CandidateBlockingSynthesizer()
        let subject = DiscardingStablePrefixSynthesizer(
            sessionID: UUID(),
            synthesizer: synthesizer,
            telemetry: recorder,
            clock: SystemMonotonicClock()
        )
        let utteranceID = UUID()

        await subject.submit(candidate: "こん", utteranceID: utteranceID)
        await synthesizer.waitUntilStarted()
        await subject.finish(final: "こんにちは", utteranceID: utteranceID)
        await subject.stop()

        #expect(await synthesizer.wasCancelled)
        let events = await recorder.events
        #expect(events.contains { $0.name == .shadowSynthesisCancelled })
    }

    @Test
    func finalDoesNotWaitForComparisonTelemetry() async {
        let recorder = CandidateBlockingComparisonRecorder()
        let synthesizer = CandidateBlockingSynthesizer()
        let completion = CandidateCompletionFlag()
        let subject = DiscardingStablePrefixSynthesizer(
            sessionID: UUID(),
            synthesizer: synthesizer,
            telemetry: recorder,
            clock: SystemMonotonicClock()
        )
        let utteranceID = UUID()

        await subject.submit(candidate: "こん", utteranceID: utteranceID)
        await synthesizer.waitUntilStarted()
        let finish = Task {
            await subject.finish(final: "こんにちは", utteranceID: utteranceID)
            await completion.markComplete()
        }
        for _ in 0..<100 where !(await completion.isComplete) {
            await Task.yield()
        }

        #expect(await completion.isComplete)

        await recorder.release()
        await finish.value
        await subject.stop()

        #expect(await synthesizer.wasCancelled)
    }

    @Test
    func candidateFailureIsRecordedAndContained() async {
        let recorder = CandidateMemoryRecorder()
        let subject = DiscardingStablePrefixSynthesizer(
            sessionID: UUID(),
            synthesizer: CandidateFailingSynthesizer(),
            telemetry: recorder,
            clock: SystemMonotonicClock()
        )

        await subject.submit(candidate: "こん", utteranceID: UUID())
        await subject.stop()

        let failures = await recorder.events.filter { $0.name == .shadowSynthesisFailed }
        #expect(failures.count == 1)
        #expect(failures.first?.errorCode == .remoteUnavailable)
    }

    @Test
    func firstCandidateComparisonIsBucketedAndContentFree() async throws {
        let recorder = CandidateMemoryRecorder()
        let subject = DiscardingStablePrefixSynthesizer(
            sessionID: UUID(),
            synthesizer: CandidateRecordingSynthesizer(),
            telemetry: recorder,
            clock: SystemMonotonicClock()
        )
        let utteranceID = UUID()

        await subject.submit(candidate: "こん", utteranceID: utteranceID)
        await subject.finish(final: "こんに", utteranceID: utteranceID)
        await subject.stop()

        let events = await recorder.events
        let comparison = events.last {
            $0.name == .shadowSynthesisFinalComparison
        }
        #expect(comparison?.metrics.shadowCandidateMatchRatio == 1)
        #expect(comparison?.metrics.shadowFinalCoverageRatio == 0.7)

        let encoded = try JSONEncoder.telemetry.encode(events)
        let json = try #require(String(data: encoded, encoding: .utf8))
        for forbidden in [
            "こん", "こんに", "text", "length", "hash", "path", "url", "voice", "device",
        ] {
            #expect(!json.lowercased().contains(forbidden.lowercased()))
        }
    }

    @Test
    func cancellationFlushesPendingFinalComparison() async {
        let recorder = CandidateMemoryRecorder()
        let synthesizer = CandidateBlockingSynthesizer()
        let subject = DiscardingStablePrefixSynthesizer(
            sessionID: UUID(),
            synthesizer: synthesizer,
            telemetry: recorder,
            clock: SystemMonotonicClock()
        )
        let utteranceID = UUID()

        await subject.submit(candidate: "こん", utteranceID: utteranceID)
        await synthesizer.waitUntilStarted()
        await subject.finish(final: "こんにちは", utteranceID: utteranceID)
        await subject.cancel()

        #expect(
            await recorder.events.contains {
                $0.name == .shadowSynthesisFinalComparison
            })
    }
}

private actor CandidateMemoryRecorder: TelemetryRecording {
    private(set) var events = [TelemetryEvent]()

    func record(_ event: TelemetryEvent) -> TelemetryWriteResult {
        events.append(event)
        return .written
    }
}

private actor CandidateBlockingComparisonRecorder: TelemetryRecording {
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()
    private var released = false

    func record(_ event: TelemetryEvent) async -> TelemetryWriteResult {
        guard event.name == .shadowSynthesisFinalComparison, !released else { return .written }
        await withCheckedContinuation { releaseWaiters.append($0) }
        return .written
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor CandidateCompletionFlag {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

private actor CandidateRecordingSynthesizer: Synthesizing {
    private(set) var texts = [String]()

    func synthesize(
        text: String,
        utteranceID _: UUID,
        onMilestone: @Sendable (SynthesisMilestone) async -> Void
    ) async throws -> AudioClip {
        texts.append(text)
        await onMilestone(.handshake)
        await onMilestone(.firstAudioPayload)
        await onMilestone(.completed(serverElapsedMilliseconds: 5, samplingSteps: 12))
        return AudioClip(wavBytes: Data([1, 2, 3]), durationMilliseconds: 12)
    }
}

private actor CandidateBlockingSynthesizer: Synthesizing {
    private(set) var wasCancelled = false
    private var started = false
    private var startedWaiters = [CheckedContinuation<Void, Never>]()

    func synthesize(
        text _: String,
        utteranceID _: UUID,
        onMilestone _: @Sendable (SynthesisMilestone) async -> Void
    ) async throws -> AudioClip {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        do {
            try await Task.sleep(for: .seconds(60))
            return AudioClip(wavBytes: Data(), durationMilliseconds: 0)
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
}

private actor CandidateFailingSynthesizer: Synthesizing {
    func synthesize(
        text _: String,
        utteranceID _: UUID,
        onMilestone _: @Sendable (SynthesisMilestone) async -> Void
    ) async throws -> AudioClip {
        throw IrodoriClientError.remoteUnavailable
    }
}
