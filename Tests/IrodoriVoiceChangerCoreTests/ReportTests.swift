import Foundation
import Testing

@testable import IrodoriVoiceChangerCore

@Suite("ReportTests")
struct ReportTests {
    @Test
    func summarizesSemanticEndpointDecisionsAndInferenceDuration() {
        let sessionID = UUID()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let events = [
            event(sessionID, first, 10, .semanticEndpointRequested),
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: first,
                timestampNanoseconds: 20,
                name: .semanticEndpointCompleted,
                stage: .speech,
                metrics: .init(
                    durationMilliseconds: 10,
                    semanticProbabilityBucket: 3,
                    semanticTurnComplete: true
                )
            ),
            event(sessionID, second, 30, .semanticEndpointRequested),
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: second,
                timestampNanoseconds: 40,
                name: .semanticEndpointCompleted,
                stage: .speech,
                metrics: .init(
                    durationMilliseconds: 20,
                    semanticProbabilityBucket: 0,
                    semanticTurnComplete: false
                )
            ),
            event(sessionID, third, 50, .semanticEndpointRequested),
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: third,
                timestampNanoseconds: 60,
                name: .semanticEndpointFailed,
                stage: .speech,
                errorCode: .speechUnavailable,
                metrics: .init(durationMilliseconds: 30)
            ),
            event(sessionID, third, 70, .sessionStopped),
        ]

        let report = TelemetryReportBuilder.build(events: events, sessionID: sessionID)

        #expect(report.semanticEndpointRequestedCount == 3)
        #expect(report.semanticEndpointCompleteCount == 1)
        #expect(report.semanticEndpointIncompleteCount == 1)
        #expect(report.semanticEndpointFailureCount == 1)
        #expect(report.metrics[.semanticInferenceDuration]?.count == 3)
        #expect(report.metrics[.semanticInferenceDuration]?.p50 == 20)
        #expect(report.incomplete)
    }

    @Test
    func unmatchedSemanticRequestMarksStoppedSessionIncomplete() {
        let sessionID = UUID()
        let utteranceID = UUID()
        let events = [
            event(sessionID, utteranceID, 1, .semanticEndpointRequested),
            event(sessionID, utteranceID, 2, .sessionStopped),
        ]

        let report = TelemetryReportBuilder.build(events: events, sessionID: sessionID)

        #expect(report.incomplete)
    }

    @Test
    func summarizesEndpointFinalizationAttempts() {
        let sessionID = UUID()
        let first = UUID()
        let second = UUID()
        let events = [
            event(sessionID, first, 100_000_000, .shadowEndpointFinalizeRequested),
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: first,
                timestampNanoseconds: 150_000_000,
                name: .shadowEndpointFinalizeCompleted,
                stage: .speech,
                metrics: .init(durationMilliseconds: 50)
            ),
            event(sessionID, second, 200_000_000, .shadowEndpointFinalizeRequested),
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: second,
                timestampNanoseconds: 220_000_000,
                name: .shadowEndpointFinalizeFailed,
                stage: .speech,
                errorCode: .speechUnavailable,
                metrics: .init(durationMilliseconds: 20)
            ),
            event(sessionID, second, 230_000_000, .sessionStopped),
        ]

        let report = TelemetryReportBuilder.build(events: events, sessionID: sessionID)

        #expect(report.endpointFinalizeRequestedCount == 2)
        #expect(report.endpointFinalizeCompletedCount == 1)
        #expect(report.endpointFinalizeFailureCount == 1)
        #expect(report.metrics[.endpointFinalizeDuration]?.count == 2)
        #expect(report.metrics[.endpointFinalizeDuration]?.p50 == 20)
    }

    @Test
    func summarizesEndpointShadowAccuracyLeadAndSpeechResumption() {
        let sessionID = UUID()
        let first = UUID()
        let second = UUID()
        let events = [
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: first,
                timestampNanoseconds: 100_000_000,
                name: .shadowEndpointCandidate,
                metrics: .init(
                    endpointSilenceMilliseconds: 300,
                    shadowCandidatePresent: true
                )
            ),
            event(sessionID, first, 200_000_000, .shadowEndpointSpeechResumed),
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: first,
                timestampNanoseconds: 900_000_000,
                name: .shadowEndpointFinalComparison,
                metrics: .init(
                    durationMilliseconds: 800,
                    endpointSilenceMilliseconds: 300,
                    shadowCandidatePresent: true,
                    shadowCandidateMatchRatio: 1,
                    shadowFinalCoverageRatio: 0.8
                )
            ),
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: second,
                timestampNanoseconds: 1_000_000_000,
                name: .shadowEndpointCandidate,
                metrics: .init(
                    endpointSilenceMilliseconds: 300,
                    shadowCandidatePresent: false
                )
            ),
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: second,
                timestampNanoseconds: 1_500_000_000,
                name: .shadowEndpointFinalComparison,
                metrics: .init(
                    durationMilliseconds: 500,
                    endpointSilenceMilliseconds: 300,
                    shadowCandidatePresent: false,
                    shadowCandidateMatchRatio: 0,
                    shadowFinalCoverageRatio: 0
                )
            ),
            event(sessionID, second, 1_600_000_000, .sessionStopped),
        ]

        let report = TelemetryReportBuilder.build(events: events, sessionID: sessionID)

        #expect(report.endpointShadowSilenceMilliseconds == 300)
        #expect(report.endpointShadowCandidateCount == 2)
        #expect(report.endpointShadowCandidatePresentCount == 1)
        #expect(report.endpointShadowSpeechResumedCount == 1)
        #expect(report.metrics[.endpointCandidateToFinal]?.p50 == 500)
        #expect(report.metrics[.endpointCandidateMatchRatio]?.p50 == 1)
        #expect(report.metrics[.endpointFinalCoverageRatio]?.p50 == 0.8)
    }

    @Test
    func summarizesDiscardedCandidateSynthesisWithoutContaminatingFinalMetrics() {
        let sessionID = UUID()
        let completedID = UUID()
        let cancelledID = UUID()
        let failedID = UUID()
        let events = [
            event(sessionID, completedID, 100_000_000, .shadowSynthesisStarted),
            event(sessionID, completedID, 150_000_000, .shadowSynthesisHandshake),
            event(sessionID, completedID, 500_000_000, .shadowSynthesisFirstAudio),
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: completedID,
                timestampNanoseconds: 700_000_000,
                name: .shadowSynthesisCompleted,
                metrics: .init(
                    durationMilliseconds: 600,
                    serverDurationMilliseconds: 500
                )
            ),
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: completedID,
                timestampNanoseconds: 800_000_000,
                name: .shadowSynthesisFinalComparison,
                metrics: .init(
                    shadowCandidatePresent: true,
                    shadowCandidateMatchRatio: 1,
                    shadowFinalCoverageRatio: 0.4
                )
            ),
            event(sessionID, completedID, 900_000_000, .asrFinal),
            event(sessionID, cancelledID, 1_000_000_000, .shadowSynthesisStarted),
            event(sessionID, cancelledID, 1_100_000_000, .shadowSynthesisCancelled),
            event(sessionID, failedID, 1_200_000_000, .shadowSynthesisStarted),
            event(sessionID, failedID, 1_300_000_000, .shadowSynthesisFailed),
            event(sessionID, completedID, 1_400_000_000, .sessionStopped),
        ]

        let report = TelemetryReportBuilder.build(events: events, sessionID: sessionID)

        #expect(report.shadowSynthesisStartedCount == 3)
        #expect(report.shadowSynthesisCompletedCount == 1)
        #expect(report.shadowSynthesisCancelledCount == 1)
        #expect(report.shadowSynthesisFailureCount == 1)
        #expect(report.metrics[.shadowSynthesisRequestToHandshake]?.p50 == 50)
        #expect(report.metrics[.shadowSynthesisRequestToFirstAudio]?.p50 == 400)
        #expect(report.metrics[.shadowSynthesisRequestToComplete]?.p50 == 600)
        #expect(report.metrics[.shadowSynthesisServerElapsed]?.p50 == 500)
        #expect(report.metrics[.shadowSynthesisRequestMinusServer]?.p50 == 100)
        #expect(report.metrics[.shadowSynthesisCandidateMatchRatio]?.p50 == 1)
        #expect(report.metrics[.shadowSynthesisFinalCoverageRatio]?.p50 == 0.4)
        #expect(report.metrics[.requestToFirstAudio] == nil)
        #expect(report.playbackCompletedCount == 0)
        #expect(report.failureCount == 0)
    }

    @Test
    func summarizesStablePrefixShadowLeadAndAccuracy() {
        let sessionID = UUID()
        let utteranceID = UUID()
        let events = [
            event(sessionID, utteranceID, 100_000_000, .speechStarted),
            event(sessionID, utteranceID, 300_000_000, .shadowPrefixCandidate),
            event(sessionID, utteranceID, 400_000_000, .shadowPrefixCandidate),
            event(sessionID, utteranceID, 500_000_000, .shadowPrefixRewrite),
            event(sessionID, utteranceID, 600_000_000, .shadowPrefixRollback),
            shadowComparisonEvent(
                sessionID,
                utteranceID,
                900_000_000,
                candidatePresent: true,
                candidateMatchRatio: 1,
                finalCoverageRatio: 0.6
            ),
            event(sessionID, utteranceID, 901_000_000, .asrFinal),
            event(sessionID, utteranceID, 1_000_000_000, .sessionStopped),
        ]

        let report = TelemetryReportBuilder.build(events: events, sessionID: sessionID)

        #expect(report.shadowCandidateUtteranceCount == 1)
        #expect(report.shadowRewriteCount == 1)
        #expect(report.shadowRollbackCount == 1)
        #expect(report.metrics[.speechStartToShadowCandidate]?.p50 == 200)
        #expect(report.metrics[.shadowCandidateToFinal]?.p50 == 600)
        #expect(report.metrics[.shadowCandidateMatchRatio]?.p50 == 1)
        #expect(report.metrics[.shadowFinalCoverageRatio]?.p50 == 0.6)
    }

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
    func unmatchedEndpointCandidateMarksStoppedSessionIncomplete() {
        let sessionID = UUID()
        let utteranceID = UUID()
        let events = [
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: utteranceID,
                timestampNanoseconds: 1,
                name: .shadowEndpointCandidate,
                metrics: .init(
                    endpointSilenceMilliseconds: 300,
                    shadowCandidatePresent: true
                )
            ),
            event(sessionID, utteranceID, 2, .sessionStopped),
        ]

        let report = TelemetryReportBuilder.build(events: events, sessionID: sessionID)

        #expect(report.incomplete)
    }

    @Test
    func endpointQueueOverflowMarksStoppedSessionIncomplete() {
        let sessionID = UUID()
        let utteranceID = UUID()
        let events = [
            event(sessionID, utteranceID, 1, .shadowEndpointOverflow),
            event(sessionID, utteranceID, 2, .sessionStopped),
        ]

        let report = TelemetryReportBuilder.build(events: events, sessionID: sessionID)

        #expect(report.incomplete)
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

    private func shadowComparisonEvent(
        _ sessionID: UUID,
        _ utteranceID: UUID,
        _ timestamp: UInt64,
        candidatePresent: Bool,
        candidateMatchRatio: Double,
        finalCoverageRatio: Double
    ) -> TelemetryEvent {
        TelemetryEvent(
            sessionID: sessionID,
            utteranceID: utteranceID,
            timestampNanoseconds: timestamp,
            name: .shadowFinalComparison,
            metrics: .init(
                shadowCandidatePresent: candidatePresent,
                shadowCandidateMatchRatio: candidateMatchRatio,
                shadowFinalCoverageRatio: finalCoverageRatio
            )
        )
    }
}
