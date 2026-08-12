import Foundation
import IrodoriVoiceChangerCore

extension CLIApplication {
    static func printTelemetryReport(session: String, path: String?, json: Bool) throws {
        let configuration = try loadConfiguration(path: path)
        let events = try TelemetryEventReader.load(
            from: URL(filePath: expand(configuration.telemetry.directory)))
        let sessionID: UUID
        if session == "latest" {
            guard let latest = TelemetryReportBuilder.latestSessionID(events: events) else {
                throw CLIExecutionError.noTelemetry
            }
            sessionID = latest
        } else if let parsed = UUID(uuidString: session) {
            sessionID = parsed
        } else {
            throw CLIUsageError()
        }
        let report = TelemetryReportBuilder.build(events: events, sessionID: sessionID)
        if json {
            guard
                let encoded = String(
                    data: try JSONEncoder.telemetry.encode(report),
                    encoding: .utf8
                )
            else {
                throw CLIExecutionError.invalidOutput
            }
            print(encoded)
            return
        }
        print("session=\(sessionID.uuidString.lowercased())")
        print(
            "utterances=\(report.utteranceCount) completed=\(report.playbackCompletedCount) "
                + "dropped=\(report.droppedCount) failures=\(report.failureCount) "
                + "input_drops=\(report.inputDropCount) max_queue=\(report.maximumQueueDepth) "
                + "underruns=\(report.queueUnderrunCount) revisions=\(report.partialRevisionCount) "
                + "rewrite_rejected=\(report.rewriteRejectedCount) "
                + "telemetry_failures=\(report.telemetryFailureCount) "
                + "incomplete=\(report.incomplete)")
        for metric in LatencyMetricName.allCases {
            guard let value = report.metrics[metric] else { continue }
            print(
                "\(metric.rawValue) count=\(value.count) min=\(value.minimum) "
                    + "p50=\(value.p50) p95=\(value.p95) max=\(value.maximum)")
        }
    }
}
