import Foundation
import Testing

@testable import IrodoriVoiceChangerCore

@Suite("TelemetryTests")
struct TelemetryTests {
    private let sessionID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    private let utteranceID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))

    @Test
    func telemetryNeverEncodesContent() throws {
        let event = TelemetryEvent(
            sessionID: sessionID,
            utteranceID: utteranceID,
            timestampNanoseconds: 42,
            name: .requestCompleted,
            metrics: .init(durationMilliseconds: 123, byteCount: 456)
        )

        let json = try #require(
            String(data: try JSONEncoder.telemetry.encode(event), encoding: .utf8))

        #expect(json.contains("request_completed"))
        #expect(json.contains("duration_milliseconds"))
        #expect(!json.contains("transcript"))
        #expect(!json.contains("device"))
        #expect(!json.contains("endpoint"))
        #expect(!json.contains("http"))
    }

    @Test
    func eventRoundTripsWithStableCodes() throws {
        let expected = TelemetryEvent(
            sessionID: sessionID,
            utteranceID: nil,
            timestampNanoseconds: 99,
            name: .operationFailed,
            stage: .irodori,
            errorCode: .remoteUnavailable,
            metrics: .init(queueDepth: 3, partialRevisionCount: 2)
        )

        let data = try JSONEncoder.telemetry.encode(expected)
        let decoded = try JSONDecoder.telemetry.decode(TelemetryEvent.self, from: data)

        #expect(decoded == expected)
        #expect(decoded.schemaVersion == 1)
    }

    @Test
    func nearestRankSummaryDoesNotInterpolate() {
        let summary = MetricSummary(values: [40, 10, 30, 20])

        #expect(summary?.count == 4)
        #expect(summary?.minimum == 10)
        #expect(summary?.p50 == 20)
        #expect(summary?.p95 == 40)
        #expect(summary?.maximum == 40)
        #expect(MetricSummary(values: []) == nil)
    }

    @Test
    func recorderWritesPrivateJSONL() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = JSONLTelemetryRecorder(
            directory: directory,
            maximumFileBytes: 4_096,
            retainedFileCount: 3
        )
        let event = TelemetryEvent(
            sessionID: sessionID,
            utteranceID: utteranceID,
            timestampNanoseconds: 7,
            name: .asrFinal
        )

        #expect(await recorder.record(event) == .written)

        let file = directory.appending(path: "events.jsonl")
        let data = try Data(contentsOf: file)
        let lines = data.split(separator: 0x0A)
        #expect(lines.count == 1)
        let decoded = try JSONDecoder.telemetry.decode(TelemetryEvent.self, from: Data(lines[0]))
        #expect(decoded == event)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func recorderRotatesAndBoundsGenerations() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = TelemetryEvent(
            sessionID: sessionID,
            utteranceID: utteranceID,
            timestampNanoseconds: 1,
            name: .asrPartial
        )
        let lineSize = try JSONEncoder.telemetry.encode(probe).count + 1
        let recorder = JSONLTelemetryRecorder(
            directory: directory,
            maximumFileBytes: lineSize,
            retainedFileCount: 2
        )

        for timestamp in 1...4 {
            let event = TelemetryEvent(
                sessionID: sessionID,
                utteranceID: utteranceID,
                timestampNanoseconds: UInt64(timestamp),
                name: .asrPartial
            )
            #expect(await recorder.record(event) == .written)
        }

        #expect(
            FileManager.default.fileExists(atPath: directory.appending(path: "events.jsonl").path))
        #expect(
            FileManager.default.fileExists(atPath: directory.appending(path: "events.1.jsonl").path)
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appending(path: "events.2.jsonl").path))
    }

    @Test
    func recorderReportsUnavailableWithoutThrowing() async throws {
        let file = temporaryDirectory().appending(path: "not-a-directory")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("occupied".utf8).write(to: file)
        let recorder = JSONLTelemetryRecorder(
            directory: file,
            maximumFileBytes: 1_024,
            retainedFileCount: 2
        )
        let event = TelemetryEvent(
            sessionID: sessionID,
            utteranceID: nil,
            timestampNanoseconds: 1,
            name: .sessionStarted
        )

        #expect(await recorder.record(event) == .unavailable)
    }

    @Test
    func sessionRecorderWarnsOnceAndPersistsFailureCountWhenStorageRecovers() async {
        let base = RecoveringTelemetryRecorder()
        let warnings = WarningCounter()
        let recorder = SessionTelemetryRecorder(base: base) {
            await warnings.increment()
        }
        let started = TelemetryEvent(
            sessionID: sessionID,
            utteranceID: nil,
            timestampNanoseconds: 1,
            name: .sessionStarted
        )
        let stopped = TelemetryEvent(
            sessionID: sessionID,
            utteranceID: nil,
            timestampNanoseconds: 2,
            name: .sessionStopped
        )

        #expect(await recorder.record(started) == .unavailable)
        #expect(await recorder.record(started) == .written)
        #expect(await recorder.record(stopped) == .written)
        #expect(await warnings.value == 1)
        #expect(await base.events.last?.metrics.telemetryFailureCount == 1)
    }

    @Test
    func systemClockUsesPositiveMonotonicTime() {
        #expect(SystemMonotonicClock().nowNanoseconds() > 0)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "irodori-voicechanger-tests")
            .appending(path: UUID().uuidString)
    }
}

private actor RecoveringTelemetryRecorder: TelemetryRecording {
    private var attempts = 0
    private(set) var events = [TelemetryEvent]()

    func record(_ event: TelemetryEvent) -> TelemetryWriteResult {
        attempts += 1
        guard attempts > 1 else { return .unavailable }
        events.append(event)
        return .written
    }
}

private actor WarningCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
