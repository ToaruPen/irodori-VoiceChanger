import Foundation
import Testing

@testable import IrodoriVoiceChangerCore

@Suite("ReportTests")
struct ReportTests {
    @Test
    func derivesPipelineIntervalsAndCompletionCounts() throws {
        let sessionID = UUID()
        let first = UUID()
        let second = UUID()
        let events = [
            preflightEvent(sessionID, 1, stage: .speech, duration: 125),
            event(sessionID, first, 80, .speechStarted),
            event(sessionID, first, 100, .speechEnded),
            timingEvent(sessionID, first, 101, .speechEndTiming, latency: 75),
            event(sessionID, first, 120, .asrFinal),
            timingEvent(sessionID, first, 119, .asrFinalTiming, latency: 20),
            revisionEvent(sessionID, first, 121, revisions: 3),
            event(sessionID, first, 130, .requestStarted),
            event(sessionID, first, 180, .firstAudioPayload),
            requestCompletedEvent(sessionID, first, 200, total: 70, server: 50),
            playbackEnqueuedEvent(sessionID, first, 210, duration: 140, depth: 2),
            event(sessionID, first, 230, .playbackStarted),
            event(sessionID, first, 300, .playbackCompleted),
            event(sessionID, first, 305, .queueUnderrun),
            event(sessionID, first, 306, .utteranceRewriteRejected),
            event(sessionID, second, 900, .speechStarted),
            event(sessionID, second, 1_000, .speechEnded),
            event(sessionID, second, 1_100, .asrFinal),
            timingEvent(sessionID, second, 1_099, .asrFinalTiming, latency: 100),
            event(sessionID, second, 1_200, .requestStarted),
            event(sessionID, second, 1_400, .firstAudioPayload),
            event(sessionID, second, 1_500, .utteranceDropped),
        ]

        let report = TelemetryReportBuilder.build(events: events, sessionID: sessionID)

        #expect(report.utteranceCount == 2)
        #expect(report.playbackCompletedCount == 1)
        #expect(report.droppedCount == 1)
        #expect(report.incomplete)
        #expect(report.maximumQueueDepth == 2)
        #expect(report.queueUnderrunCount == 1)
        #expect(report.partialRevisionCount == 3)
        #expect(report.rewriteRejectedCount == 1)
        #expect(report.metrics[.audioToFinalDelivery]?.p50 == 20)
        #expect(report.metrics[.audioToSpeechEndDelivery]?.p50 == 75)
        #expect(abs((report.metrics[.audioEndToPlayback]?.p50 ?? 0) - 20.000_11) < 0.000_001)
        #expect(report.metrics[.requestToFirstAudio]?.p95 == 0.000_2)
        #expect(report.metrics[.realTimeFactor]?.p50 == 0.5)
        #expect(report.metrics[.synthesisCompleteToPlayback]?.p50 == 0.000_03)
        #expect(report.metrics[.speechStartToPlayback]?.p50 == 0.000_15)
        #expect(report.metrics[.speechPreflight]?.p50 == 125)

        let encoded = try JSONEncoder.telemetry.encode(report)
        let decoded = try JSONDecoder.telemetry.decode(TelemetryReport.self, from: encoded)
        #expect(decoded == report)
    }

    @Test
    func telemetryFailureMarksStoppedSessionIncomplete() {
        let sessionID = UUID()
        let stopped = TelemetryEvent(
            sessionID: sessionID,
            utteranceID: nil,
            timestampNanoseconds: 10,
            name: .sessionStopped,
            stage: .lifecycle,
            metrics: .init(telemetryFailureCount: 1)
        )

        let report = TelemetryReportBuilder.build(events: [stopped], sessionID: sessionID)

        #expect(report.incomplete)
        #expect(report.telemetryFailureCount == 1)
    }

    @Test
    func eventReaderLoadsRotatedJSONLInAppendOrderAndHandlesMissingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try TelemetryEventReader.load(from: root).isEmpty)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = event(UUID(), UUID(), 1, .speechStarted)
        let second = event(first.sessionID, try #require(first.utteranceID), 2, .asrPartial)
        let third = event(first.sessionID, try #require(first.utteranceID), 3, .asrFinal)
        let firstLine = try JSONEncoder.telemetry.encode(first) + Data([0x0A])
        let secondLine = try JSONEncoder.telemetry.encode(second) + Data([0x0A])
        let thirdLine = try JSONEncoder.telemetry.encode(third) + Data([0x0A])
        try firstLine.write(to: root.appending(path: "events.2.jsonl"))
        try secondLine.write(to: root.appending(path: "events.1.jsonl"))
        try thirdLine.write(to: root.appending(path: "events.jsonl"))
        try Data("ignored".utf8).write(to: root.appending(path: "other.txt"))

        let loaded = try TelemetryEventReader.load(from: root)
        #expect(loaded.map(\.timestampNanoseconds) == [1, 2, 3])
    }

    @Test
    func reportEncodingContainsNoContentOrIdentifiersBeyondSessionCorrelation() throws {
        let sessionID = UUID()
        let report = TelemetryReportBuilder.build(events: [], sessionID: sessionID)
        let json = try #require(
            String(data: try JSONEncoder.telemetry.encode(report), encoding: .utf8))

        #expect(json.lowercased().contains(sessionID.uuidString.lowercased()))
        #expect(!json.contains("transcript"))
        #expect(!json.contains("device"))
        #expect(!json.contains("voice"))
        #expect(!json.contains("http"))
    }

    @Test
    func latestSessionSelectionUsesAppendOrderAcrossReboots() throws {
        let beforeReboot = event(UUID(), UUID(), 900_000, .sessionStopped)
        let afterReboot = event(UUID(), UUID(), 100, .sessionStopped)

        let latest = TelemetryReportBuilder.latestSessionID(events: [beforeReboot, afterReboot])

        #expect(latest == afterReboot.sessionID)
    }

    private func event(
        _ sessionID: UUID,
        _ utteranceID: UUID,
        _ timestamp: UInt64,
        _ name: TelemetryEventName
    ) -> TelemetryEvent {
        TelemetryEvent(
            sessionID: sessionID,
            utteranceID: utteranceID,
            timestampNanoseconds: timestamp,
            name: name
        )
    }

    private func timingEvent(
        _ sessionID: UUID,
        _ utteranceID: UUID,
        _ timestamp: UInt64,
        _ name: TelemetryEventName,
        latency: Double
    ) -> TelemetryEvent {
        TelemetryEvent(
            sessionID: sessionID,
            utteranceID: utteranceID,
            timestampNanoseconds: timestamp,
            name: name,
            metrics: .init(sourceLatencyMilliseconds: latency)
        )
    }

    private func requestCompletedEvent(
        _ sessionID: UUID,
        _ utteranceID: UUID,
        _ timestamp: UInt64,
        total: Double,
        server: Double
    ) -> TelemetryEvent {
        TelemetryEvent(
            sessionID: sessionID,
            utteranceID: utteranceID,
            timestampNanoseconds: timestamp,
            name: .requestCompleted,
            metrics: .init(
                durationMilliseconds: total,
                serverDurationMilliseconds: server
            )
        )
    }

    private func playbackEnqueuedEvent(
        _ sessionID: UUID,
        _ utteranceID: UUID,
        _ timestamp: UInt64,
        duration: Double,
        depth: Int
    ) -> TelemetryEvent {
        TelemetryEvent(
            sessionID: sessionID,
            utteranceID: utteranceID,
            timestampNanoseconds: timestamp,
            name: .playbackEnqueued,
            metrics: .init(audioDurationMilliseconds: duration, queueDepth: depth)
        )
    }

    private func revisionEvent(
        _ sessionID: UUID,
        _ utteranceID: UUID,
        _ timestamp: UInt64,
        revisions: Int
    ) -> TelemetryEvent {
        TelemetryEvent(
            sessionID: sessionID,
            utteranceID: utteranceID,
            timestampNanoseconds: timestamp,
            name: .asrFinal,
            metrics: .init(partialRevisionCount: revisions)
        )
    }

    private func preflightEvent(
        _ sessionID: UUID,
        _ timestamp: UInt64,
        stage: PipelineStage,
        duration: Double
    ) -> TelemetryEvent {
        TelemetryEvent(
            sessionID: sessionID,
            utteranceID: nil,
            timestampNanoseconds: timestamp,
            name: .preflightCompleted,
            stage: stage,
            metrics: .init(durationMilliseconds: duration)
        )
    }
}
