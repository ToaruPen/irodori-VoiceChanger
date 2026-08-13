import Foundation
import Testing

@testable import IrodoriVoiceChangerCore

@Suite("EndpointFinalizationTests")
struct EndpointFinalizationTests {
    @Test
    func successRecordsRequestedAndCompletedWithDuration() async {
        let recorder = FinalizationMemoryRecorder()
        let operation = FinalizationOperationSpy()
        let handler = EndpointFinalizationHandler(
            sessionID: UUID(),
            telemetry: recorder,
            clock: FinalizationSequenceClock(values: [100_000_000, 150_000_000]),
            operation: { try await operation.run() }
        )
        let utteranceID = UUID()

        _ = await handler.handleEndpointCandidate(utteranceID: utteranceID)

        #expect(await operation.callCount == 1)
        let events = await recorder.events
        #expect(
            events.map(\.name) == [
                .shadowEndpointFinalizeRequested,
                .shadowEndpointFinalizeCompleted,
            ])
        #expect(events.allSatisfy { $0.utteranceID == utteranceID })
        #expect(events.last?.metrics.durationMilliseconds == 50)
        #expect(await handler.failureRequiringStop() == nil)
    }

    @Test
    func failureIsRecordedAndExposedWithoutEscapingHandler() async {
        let recorder = FinalizationMemoryRecorder()
        let handler = EndpointFinalizationHandler(
            sessionID: UUID(),
            telemetry: recorder,
            clock: FinalizationSequenceClock(values: [100_000_000, 120_000_000]),
            operation: { throw FinalizationTestError.failed }
        )

        _ = await handler.handleEndpointCandidate(utteranceID: UUID())

        let events = await recorder.events
        #expect(
            events.map(\.name) == [
                .shadowEndpointFinalizeRequested,
                .shadowEndpointFinalizeFailed,
            ])
        #expect(events.last?.errorCode == .speechUnavailable)
        #expect(events.last?.metrics.durationMilliseconds == 20)
        #expect(await handler.failureRequiringStop() == .speechUnavailable)
    }
}

private enum FinalizationTestError: Error {
    case failed
}

private actor FinalizationOperationSpy {
    private(set) var callCount = 0

    func run() throws {
        callCount += 1
    }
}

private actor FinalizationMemoryRecorder: TelemetryRecording {
    private(set) var events = [TelemetryEvent]()

    func record(_ event: TelemetryEvent) -> TelemetryWriteResult {
        events.append(event)
        return .written
    }
}

private struct FinalizationSequenceClock: MonotonicClock {
    private let state: FinalizationClockState

    init(values: [UInt64]) {
        state = FinalizationClockState(values: values)
    }

    func nowNanoseconds() -> UInt64 {
        state.next()
    }
}

private final class FinalizationClockState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64 {
        lock.withLock {
            guard !values.isEmpty else { return 0 }
            return values.removeFirst()
        }
    }
}
