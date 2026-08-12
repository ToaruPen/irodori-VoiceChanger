import Darwin
import Foundation
import IrodoriVoiceChangerCore

struct StagedRuntimeError: Error {
    let stage: PipelineStage
    let code: StableErrorCode
}

struct DoctorProbeEventFactory {
    let sessionID: UUID
    let probeID: UUID

    func requestStarted(timestamp: UInt64) -> TelemetryEvent {
        TelemetryEvent(
            sessionID: sessionID,
            utteranceID: probeID,
            timestampNanoseconds: timestamp,
            name: .requestStarted,
            stage: .irodori
        )
    }

    func milestone(
        _ milestone: SynthesisMilestone,
        timestamp: UInt64,
        requestStarted: UInt64?
    ) -> TelemetryEvent {
        let (name, metrics): (TelemetryEventName, TelemetryMetrics) =
            switch milestone {
            case .handshake: (.streamHandshake, .init())
            case .firstAudioPayload: (.firstAudioPayload, .init())
            case .completed(let server, let steps):
                (
                    .requestCompleted,
                    .init(
                        durationMilliseconds: requestStarted.map {
                            Double(timestamp - $0) / 1_000_000
                        },
                        serverDurationMilliseconds: server,
                        samplingSteps: steps
                    )
                )
            }
        return TelemetryEvent(
            sessionID: sessionID,
            utteranceID: probeID,
            timestampNanoseconds: timestamp,
            name: name,
            stage: .irodori,
            metrics: metrics
        )
    }
}

struct SpeechTelemetryMapping {
    let name: TelemetryEventName
    let utteranceID: UUID
    let revisionCount: Int?
}

actor DiscardingAudioPlayer: AudioPlaying {
    func play(_: AudioClip, utteranceID _: UUID) async throws {}
}

enum TerminationSignals {
    static func stream() -> AsyncStream<Int32> {
        AsyncStream { continuation in
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let sources = SignalSourceStorage(
                signals: [SIGINT, SIGTERM],
                continuation: continuation
            )
            sources.start()
            continuation.onTermination = { _ in sources.cancel() }
        }
    }
}

private final class SignalSourceStorage: @unchecked Sendable {
    private let sources: [DispatchSourceSignal]

    init(signals: [Int32], continuation: AsyncStream<Int32>.Continuation) {
        sources = signals.map { signal in
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .global())
            source.setEventHandler {
                continuation.yield(signal)
                continuation.finish()
            }
            return source
        }
    }

    func start() {
        sources.forEach { $0.activate() }
    }

    func cancel() {
        sources.forEach { $0.cancel() }
    }
}
