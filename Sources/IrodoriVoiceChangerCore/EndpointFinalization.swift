import Foundation

public actor EndpointFinalizationHandler: EndpointCandidateHandling {
    private let sessionID: UUID
    private let telemetry: any TelemetryRecording
    private let clock: any MonotonicClock
    private let operation: @Sendable () async throws -> Void
    private var failure: StableErrorCode?

    public init(
        sessionID: UUID,
        telemetry: any TelemetryRecording,
        clock: any MonotonicClock,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        self.sessionID = sessionID
        self.telemetry = telemetry
        self.clock = clock
        self.operation = operation
    }

    public func handleEndpointCandidate(
        utteranceID: UUID
    ) async -> EndpointCandidateDisposition {
        guard failure == nil else { return .terminal }
        let started = clock.nowNanoseconds()
        await record(
            .shadowEndpointFinalizeRequested,
            utteranceID: utteranceID,
            timestamp: started
        )
        do {
            try await operation()
            let completed = clock.nowNanoseconds()
            await record(
                .shadowEndpointFinalizeCompleted,
                utteranceID: utteranceID,
                timestamp: completed,
                durationMilliseconds: elapsedMilliseconds(from: started, to: completed)
            )
        } catch {
            let completed = clock.nowNanoseconds()
            failure = .speechUnavailable
            await record(
                .shadowEndpointFinalizeFailed,
                utteranceID: utteranceID,
                timestamp: completed,
                durationMilliseconds: elapsedMilliseconds(from: started, to: completed),
                errorCode: .speechUnavailable
            )
        }
        return .terminal
    }

    public func failureRequiringStop() -> StableErrorCode? {
        failure
    }

    private func record(
        _ name: TelemetryEventName,
        utteranceID: UUID,
        timestamp: UInt64,
        durationMilliseconds: Double? = nil,
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
                metrics: .init(durationMilliseconds: durationMilliseconds)
            ))
    }

    private func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - min(start, end)) / 1_000_000
    }
}
