import Foundation
import Testing

@testable import IrodoriVoiceChangerCore

@Suite("DoctorTests")
struct DoctorTests {
    @Test
    func doctorReportUsesOnlyStableCodesAndStatuses() throws {
        let report = DoctorReport(checks: [
            .init(code: .operatingSystem, status: .passed),
            .init(code: .microphonePermission, status: .attention),
            .init(code: .irodoriReadiness, status: .failed, errorCode: .remoteUnavailable),
        ])
        let json = try #require(
            String(data: try JSONEncoder.telemetry.encode(report), encoding: .utf8))

        #expect(json.contains("operating_system"))
        #expect(json.contains("remote_unavailable"))
        #expect(!json.contains("detail"))
        #expect(!json.contains("identifier"))
        #expect(report.exitCode == 1)
    }

    @Test
    func attentionDoesNotFailDoctorButFailuresDo() {
        #expect(
            DoctorReport(checks: [.init(code: .microphonePermission, status: .attention)]).exitCode
                == 0)
        #expect(
            DoctorReport(checks: [.init(code: .configuration, status: .failed)]).exitCode == 1)
    }
}
