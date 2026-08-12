import Foundation
import Testing

@testable import IrodoriVoiceChangerCore

@Suite("PipelineTests")
struct PipelineTests {
    @Test
    func oneUtteranceEmitsTheCompleteOrderedTimeline() async throws {
        let recorder = MemoryTelemetryRecorder()
        let synthesizer = FakeSynthesizer()
        let player = FakePlayer()
        let pipeline = VoiceChangerPipeline(
            synthesizer: synthesizer,
            player: player,
            telemetry: recorder,
            clock: IncrementingClock(),
            maximumPendingSynthesis: 2,
            maximumPendingPlayback: 2
        )
        let utteranceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000010"))

        await pipeline.handle(.speechStarted(utteranceID))
        await pipeline.handle(.partial(utteranceID, text: "こん", revisionCount: 0))
        await pipeline.handle(.timing(utteranceID, kind: .speechEnd, deliveryMilliseconds: 75))
        await pipeline.handle(.speechEnded(utteranceID))
        await pipeline.handle(.final(utteranceID, text: "こんにちは", revisionCount: 1))
        await pipeline.waitUntilIdle()

        let names = await recorder.events.map(\.name)
        #expect(
            names == [
                .speechStarted, .asrPartial, .speechEndTiming, .speechEnded, .asrFinal,
                .utteranceCommitted,
                .requestStarted, .streamHandshake, .firstAudioPayload, .requestCompleted,
                .playbackEnqueued, .playbackStarted, .playbackCompleted,
            ])
        #expect(await synthesizer.texts == ["こんにちは"])
        #expect(await player.playedIDs == [utteranceID])
    }

    @Test
    func boundedSynthesisQueueDropsNewestWithoutReordering() async throws {
        let recorder = MemoryTelemetryRecorder()
        let synthesizer = GateSynthesizer()
        let pipeline = VoiceChangerPipeline(
            synthesizer: synthesizer,
            player: FakePlayer(),
            telemetry: recorder,
            clock: IncrementingClock(),
            maximumPendingSynthesis: 1,
            maximumPendingPlayback: 2
        )
        let first = UUID()
        let second = UUID()
        let third = UUID()

        await pipeline.handle(.final(first, text: "一", revisionCount: 0))
        await synthesizer.waitUntilStarted()
        await pipeline.handle(.final(second, text: "二", revisionCount: 0))
        await pipeline.handle(.final(third, text: "三", revisionCount: 0))
        await synthesizer.releaseAll()
        await pipeline.waitUntilIdle()

        #expect(await synthesizer.texts == ["一", "二"])
        let dropped = await recorder.events.filter { $0.name == .utteranceDropped }
        #expect(dropped.count == 1)
        #expect(dropped.first?.utteranceID == third)
    }

    @Test
    func threeConsecutiveRemoteFailuresStopTheSession() async {
        let recorder = MemoryTelemetryRecorder()
        let synthesizer = FailingThenSuccessfulSynthesizer()
        let pipeline = VoiceChangerPipeline(
            synthesizer: synthesizer,
            player: FakePlayer(),
            telemetry: recorder,
            clock: IncrementingClock(),
            maximumPendingSynthesis: 4,
            maximumPendingPlayback: 2
        )

        for value in 0..<4 {
            await pipeline.handle(.final(UUID(), text: "\(value)", revisionCount: 0))
        }
        await pipeline.waitUntilIdle()

        let failures = await recorder.events.filter { $0.name == .operationFailed }
        #expect(failures.count == 3)
        #expect(failures.allSatisfy { $0.errorCode == .remoteUnavailable })
        #expect(await synthesizer.invocationCount == 3)
        #expect(await pipeline.failureRequiringRestart() == .remoteUnavailable)
    }

    @Test
    func generationMismatchAndPlayerFailureStopImmediately() async {
        let generationPipeline = VoiceChangerPipeline(
            synthesizer: ClientErrorSynthesizer(error: .remote(.runtimeGenerationMismatch)),
            player: FakePlayer(),
            telemetry: MemoryTelemetryRecorder(),
            clock: IncrementingClock(),
            maximumPendingSynthesis: 1,
            maximumPendingPlayback: 1
        )
        await generationPipeline.handle(.final(UUID(), text: "test", revisionCount: 0))
        await generationPipeline.waitUntilIdle()
        #expect(
            await generationPipeline.failureRequiringRestart()
                == .runtimeGenerationMismatch)

        let playbackPipeline = VoiceChangerPipeline(
            synthesizer: FakeSynthesizer(),
            player: FailingPlayer(),
            telemetry: MemoryTelemetryRecorder(),
            clock: IncrementingClock(),
            maximumPendingSynthesis: 1,
            maximumPendingPlayback: 1
        )
        await playbackPipeline.handle(.final(UUID(), text: "test", revisionCount: 0))
        await playbackPipeline.waitUntilIdle()
        #expect(await playbackPipeline.failureRequiringRestart() == .outputUnavailable)
    }

    @Test
    func restartFailureStreamSignalsFatalFailure() async {
        let pipeline = VoiceChangerPipeline(
            synthesizer: ClientErrorSynthesizer(error: .remote(.runtimeGenerationMismatch)),
            player: FakePlayer(),
            telemetry: MemoryTelemetryRecorder(),
            clock: IncrementingClock(),
            maximumPendingSynthesis: 1,
            maximumPendingPlayback: 1
        )
        let failures = await pipeline.restartFailures()

        await pipeline.handle(.final(UUID(), text: "test", revisionCount: 0))
        let failure = await failures.first { _ in true }

        #expect(failure == .runtimeGenerationMismatch)
    }

    @Test
    func finiteSpeechSourceStopsPipelineAndEmptyFinalIsDropped() async throws {
        let recorder = MemoryTelemetryRecorder()
        let id = UUID()
        let pipeline = VoiceChangerPipeline(
            synthesizer: FakeSynthesizer(),
            player: FakePlayer(),
            telemetry: recorder,
            clock: IncrementingClock(),
            maximumPendingSynthesis: 2,
            maximumPendingPlayback: 2
        )
        let source = ArraySpeechSource(events: [
            .speechStarted(id), .speechEnded(id), .final(id, text: "   ", revisionCount: 0),
        ])

        try await pipeline.run(source: source)
        await pipeline.handle(.final(UUID(), text: "ignored after stop", revisionCount: 0))

        let events = await recorder.events
        #expect(events.filter { $0.name == .utteranceDropped }.count == 1)
        #expect(events.filter { $0.name == .requestStarted }.isEmpty)
    }

    @Test
    func playbackQueueIsBoundedWhileActivePlaybackIsPreserved() async {
        let recorder = MemoryTelemetryRecorder()
        let player = GatePlayer()
        let pipeline = VoiceChangerPipeline(
            synthesizer: FakeSynthesizer(),
            player: player,
            telemetry: recorder,
            clock: IncrementingClock(),
            maximumPendingSynthesis: 4,
            maximumPendingPlayback: 1
        )
        let first = UUID()
        let second = UUID()
        let third = UUID()

        await pipeline.handle(.final(first, text: "一", revisionCount: 0))
        await player.waitUntilStarted()
        await pipeline.handle(.final(second, text: "二", revisionCount: 0))
        await recorder.waitFor(.playbackEnqueued, count: 2)
        await pipeline.handle(.final(third, text: "三", revisionCount: 0))
        await recorder.waitFor(.utteranceDropped, count: 1)
        await player.release()
        await pipeline.waitUntilIdle()

        #expect(await player.playedIDs == [first, second])
        let drop = await recorder.events.first { $0.name == .utteranceDropped }
        #expect(drop?.utteranceID == third)
    }

    @Test
    func fatalPlaybackFailureCannotReenqueueConcurrentSynthesis() async {
        let recorder = MemoryTelemetryRecorder()
        let synthesizer = SecondGateSynthesizer()
        let player = GatedFailingPlayer()
        let pipeline = VoiceChangerPipeline(
            synthesizer: synthesizer,
            player: player,
            telemetry: recorder,
            clock: IncrementingClock(),
            maximumPendingSynthesis: 2,
            maximumPendingPlayback: 2
        )
        let first = UUID()
        let second = UUID()

        await pipeline.handle(.final(first, text: "一", revisionCount: 0))
        await player.waitUntilStarted()
        await pipeline.handle(.final(second, text: "二", revisionCount: 0))
        await synthesizer.waitUntilSecondStarted()
        await player.fail()
        await synthesizer.releaseSecond()
        await pipeline.waitUntilIdle()

        #expect(await pipeline.failureRequiringRestart() == .outputUnavailable)
        #expect(await player.playedIDs == [first])
        let dropped = await recorder.events.filter { $0.name == .utteranceDropped }
        #expect(dropped.contains { $0.utteranceID == second })
    }

    @Test
    func cancellationStopsActiveSynthesisWithoutRecordingRemoteFailure() async {
        let recorder = MemoryTelemetryRecorder()
        let synthesizer = CancellationAwareSynthesizer()
        let player = FakePlayer()
        let pipeline = VoiceChangerPipeline(
            synthesizer: synthesizer,
            player: player,
            telemetry: recorder,
            clock: IncrementingClock(),
            maximumPendingSynthesis: 1,
            maximumPendingPlayback: 1
        )
        let utteranceID = UUID()

        await pipeline.handle(.final(utteranceID, text: "停止", revisionCount: 0))
        await synthesizer.waitUntilStarted()
        await pipeline.cancel()
        await pipeline.waitUntilIdle()

        #expect(await synthesizer.wasCancelled)
        #expect(await player.playedIDs.isEmpty)
        let events = await recorder.events
        #expect(events.filter { $0.name == .operationFailed }.isEmpty)
        #expect(events.contains { $0.name == .utteranceDropped && $0.utteranceID == utteranceID })
    }

    @Test
    func cancellationBetweenDequeueAndPlayCannotStartAudio() async {
        let recorder = PlaybackStartGatingRecorder()
        let player = FakePlayer()
        let pipeline = VoiceChangerPipeline(
            synthesizer: FakeSynthesizer(),
            player: player,
            telemetry: recorder,
            clock: IncrementingClock(),
            maximumPendingSynthesis: 1,
            maximumPendingPlayback: 1
        )
        let utteranceID = UUID()

        await pipeline.handle(.final(utteranceID, text: "停止", revisionCount: 0))
        await recorder.waitUntilPlaybackStartIsBlocked()
        await pipeline.cancel()
        await recorder.releasePlaybackStart()
        await pipeline.waitUntilIdle()

        #expect(await player.playedIDs.isEmpty)
        let events = await recorder.events
        #expect(events.contains { $0.name == .utteranceDropped && $0.utteranceID == utteranceID })
    }

    @Test
    func queuedPlaybackPreventsFalseUnderrunWhileSynthesisContinues() async {
        let recorder = MemoryTelemetryRecorder()
        let synthesizer = ThirdGateSynthesizer()
        let player = TwoStageGatePlayer()
        let pipeline = VoiceChangerPipeline(
            synthesizer: synthesizer,
            player: player,
            telemetry: recorder,
            clock: IncrementingClock(),
            maximumPendingSynthesis: 3,
            maximumPendingPlayback: 2
        )

        await pipeline.handle(.final(UUID(), text: "一", revisionCount: 0))
        await player.waitUntilFirstStarted()
        await pipeline.handle(.final(UUID(), text: "二", revisionCount: 0))
        await recorder.waitFor(.playbackEnqueued, count: 2)
        await pipeline.handle(.final(UUID(), text: "三", revisionCount: 0))
        await synthesizer.waitUntilThirdStarted()
        await player.releaseFirst()
        await player.waitUntilSecondStarted()

        var underruns = await recorder.events.filter { $0.name == .queueUnderrun }
        #expect(underruns.isEmpty)

        await synthesizer.releaseThird()
        await recorder.waitFor(.playbackEnqueued, count: 3)
        await player.releaseSecond()
        await pipeline.waitUntilIdle()

        underruns = await recorder.events.filter { $0.name == .queueUnderrun }
        #expect(underruns.isEmpty)
    }

    @Test
    func irodoriAndPlaybackErrorsMapToStableTelemetryCodes() async {
        let cases: [(IrodoriClientError, StableErrorCode)] = [
            (.remoteUnavailable, .remoteUnavailable),
            (.notReady, .invalidResponse),
            (.voiceNotFound, .voiceNotFound),
            (.responseTooLarge, .responseTooLarge),
            (.remote(.backpressure), .backpressure),
            (.remote(.runtimeGenerationMismatch), .runtimeGenerationMismatch),
            (.remote(.voiceNotFound), .voiceNotFound),
            (.remote(.backendUnavailable), .remoteUnavailable),
        ]
        for (error, expected) in cases {
            let recorder = MemoryTelemetryRecorder()
            let pipeline = VoiceChangerPipeline(
                synthesizer: ClientErrorSynthesizer(error: error),
                player: FakePlayer(),
                telemetry: recorder,
                clock: IncrementingClock(),
                maximumPendingSynthesis: 1,
                maximumPendingPlayback: 1
            )
            await pipeline.handle(.final(UUID(), text: "テスト", revisionCount: 0))
            await pipeline.waitUntilIdle()
            #expect(await recorder.events.last?.errorCode == expected)
        }

        let recorder = MemoryTelemetryRecorder()
        let playbackPipeline = VoiceChangerPipeline(
            synthesizer: FakeSynthesizer(),
            player: FailingPlayer(),
            telemetry: recorder,
            clock: IncrementingClock(),
            maximumPendingSynthesis: 1,
            maximumPendingPlayback: 1
        )
        await playbackPipeline.handle(.final(UUID(), text: "テスト", revisionCount: 0))
        await playbackPipeline.waitUntilIdle()
        #expect(await recorder.events.last?.errorCode == .outputUnavailable)
    }
}

private struct IncrementingClock: MonotonicClock {
    private let state = ClockState()

    func nowNanoseconds() -> UInt64 {
        state.next()
    }
}

private final class ClockState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private actor MemoryTelemetryRecorder: TelemetryRecording {
    private(set) var events = [TelemetryEvent]()
    private var waiters = [EventWaiter]()

    func record(_ event: TelemetryEvent) -> TelemetryWriteResult {
        events.append(event)
        let ready = waiters.filter { waiter in
            events.filter { $0.name == waiter.name }.count >= waiter.count
        }
        waiters.removeAll { waiter in
            ready.contains { $0.id == waiter.id }
        }
        ready.forEach { $0.continuation.resume() }
        return .written
    }

    func waitFor(_ name: TelemetryEventName, count: Int) async {
        guard events.filter({ $0.name == name }).count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append(
                EventWaiter(id: UUID(), name: name, count: count, continuation: continuation))
        }
    }
}

private struct EventWaiter: @unchecked Sendable {
    let id: UUID
    let name: TelemetryEventName
    let count: Int
    let continuation: CheckedContinuation<Void, Never>
}

private actor FakeSynthesizer: Synthesizing {
    private(set) var texts = [String]()

    func synthesize(
        text: String,
        utteranceID _: UUID,
        onMilestone: @Sendable (SynthesisMilestone) async -> Void
    ) async throws -> AudioClip {
        texts.append(text)
        await onMilestone(.handshake)
        await onMilestone(.firstAudioPayload)
        await onMilestone(.completed(serverElapsedMilliseconds: 200, samplingSteps: 12))
        return AudioClip(wavBytes: Data("audio".utf8), durationMilliseconds: 250)
    }
}

private actor FakePlayer: AudioPlaying {
    private(set) var playedIDs = [UUID]()

    func play(_ audio: AudioClip, utteranceID: UUID) async throws {
        _ = audio
        playedIDs.append(utteranceID)
    }
}

private actor GateSynthesizer: Synthesizing {
    private(set) var texts = [String]()
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuations = [CheckedContinuation<Void, Never>]()
    private var started = false
    private var invocation = 0

    func synthesize(
        text: String,
        utteranceID _: UUID,
        onMilestone: @Sendable (SynthesisMilestone) async -> Void
    ) async throws -> AudioClip {
        texts.append(text)
        invocation += 1
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        if invocation == 1 {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
        await onMilestone(.handshake)
        await onMilestone(.firstAudioPayload)
        await onMilestone(.completed(serverElapsedMilliseconds: 1, samplingSteps: 12))
        return AudioClip(wavBytes: Data("audio".utf8), durationMilliseconds: 1)
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func releaseAll() {
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations.removeAll()
    }
}

private actor SecondGateSynthesizer: Synthesizing {
    private var invocation = 0
    private var secondStartedContinuation: CheckedContinuation<Void, Never>?
    private var secondReleaseContinuation: CheckedContinuation<Void, Never>?
    private var secondStarted = false

    func synthesize(
        text _: String,
        utteranceID _: UUID,
        onMilestone: @Sendable (SynthesisMilestone) async -> Void
    ) async throws -> AudioClip {
        invocation += 1
        if invocation == 2 {
            secondStarted = true
            secondStartedContinuation?.resume()
            secondStartedContinuation = nil
            await withCheckedContinuation { continuation in
                secondReleaseContinuation = continuation
            }
        }
        await onMilestone(.completed(serverElapsedMilliseconds: 1, samplingSteps: 12))
        return AudioClip(wavBytes: Data("audio".utf8), durationMilliseconds: 1)
    }

    func waitUntilSecondStarted() async {
        guard !secondStarted else { return }
        await withCheckedContinuation { continuation in
            secondStartedContinuation = continuation
        }
    }

    func releaseSecond() {
        secondReleaseContinuation?.resume()
        secondReleaseContinuation = nil
    }
}

private actor CancellationAwareSynthesizer: Synthesizing {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var workContinuation: CheckedContinuation<Void, Error>?
    private var started = false
    private(set) var wasCancelled = false

    func synthesize(
        text _: String,
        utteranceID _: UUID,
        onMilestone _: @Sendable (SynthesisMilestone) async -> Void
    ) async throws -> AudioClip {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                workContinuation = continuation
            }
        } onCancel: {
            Task { await self.finishCancellation() }
        }
        return AudioClip(wavBytes: Data(), durationMilliseconds: 0)
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    private func finishCancellation() {
        wasCancelled = true
        workContinuation?.resume(throwing: CancellationError())
        workContinuation = nil
    }
}

private actor ThirdGateSynthesizer: Synthesizing {
    private var invocation = 0
    private var thirdStartedContinuation: CheckedContinuation<Void, Never>?
    private var thirdReleaseContinuation: CheckedContinuation<Void, Never>?
    private var thirdStarted = false

    func synthesize(
        text _: String,
        utteranceID _: UUID,
        onMilestone: @Sendable (SynthesisMilestone) async -> Void
    ) async throws -> AudioClip {
        invocation += 1
        if invocation == 3 {
            thirdStarted = true
            thirdStartedContinuation?.resume()
            thirdStartedContinuation = nil
            await withCheckedContinuation { continuation in
                thirdReleaseContinuation = continuation
            }
        }
        await onMilestone(.completed(serverElapsedMilliseconds: 1, samplingSteps: 12))
        return AudioClip(wavBytes: Data("audio".utf8), durationMilliseconds: 1)
    }

    func waitUntilThirdStarted() async {
        guard !thirdStarted else { return }
        await withCheckedContinuation { continuation in
            thirdStartedContinuation = continuation
        }
    }

    func releaseThird() {
        thirdReleaseContinuation?.resume()
        thirdReleaseContinuation = nil
    }
}

private actor FailingThenSuccessfulSynthesizer: Synthesizing {
    private var invocation = 0
    var invocationCount: Int { invocation }

    func synthesize(
        text _: String,
        utteranceID _: UUID,
        onMilestone: @Sendable (SynthesisMilestone) async -> Void
    ) async throws -> AudioClip {
        invocation += 1
        if invocation <= 3 {
            throw PipelineOperationError(.remoteUnavailable)
        }
        await onMilestone(.completed(serverElapsedMilliseconds: 1, samplingSteps: 12))
        return AudioClip(wavBytes: Data("audio".utf8), durationMilliseconds: 1)
    }
}

private struct ArraySpeechSource: SpeechEventSource {
    let storedEvents: [SpeechEvent]

    init(events: [SpeechEvent]) {
        storedEvents = events
    }

    func events() async throws -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            storedEvents.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

private actor GatePlayer: AudioPlaying {
    private(set) var playedIDs = [UUID]()
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var firstStarted = false

    func play(_: AudioClip, utteranceID: UUID) async throws {
        playedIDs.append(utteranceID)
        guard playedIDs.count == 1 else { return }
        firstStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor GatedFailingPlayer: AudioPlaying {
    private(set) var playedIDs = [UUID]()
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var failureContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    func play(_: AudioClip, utteranceID: UUID) async throws {
        playedIDs.append(utteranceID)
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { continuation in
            failureContinuation = continuation
        }
        throw PipelineOperationError(.outputUnavailable)
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func fail() {
        failureContinuation?.resume()
        failureContinuation = nil
    }
}

private struct FailingPlayer: AudioPlaying {
    func play(_: AudioClip, utteranceID _: UUID) async throws {
        throw PipelineOperationError(.outputUnavailable)
    }
}

private struct ClientErrorSynthesizer: Synthesizing {
    let error: IrodoriClientError

    func synthesize(
        text _: String,
        utteranceID _: UUID,
        onMilestone _: @Sendable (SynthesisMilestone) async -> Void
    ) async throws -> AudioClip {
        throw error
    }
}
