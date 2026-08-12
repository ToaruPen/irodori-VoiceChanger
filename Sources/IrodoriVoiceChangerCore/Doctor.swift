import Foundation

public enum DoctorCheckCode: String, Codable, CaseIterable, Sendable {
    case operatingSystem = "operating_system"
    case configuration
    case speechLocale = "speech_locale"
    case speechAsset = "speech_asset"
    case microphonePermission = "microphone_permission"
    case irodoriReadiness = "irodori_readiness"
    case voiceResolution = "voice_resolution"
    case outputDevice = "output_device"
    case synthesisProbe = "synthesis_probe"
}

public enum DoctorCheckStatus: String, Codable, Sendable {
    case passed
    case attention
    case failed
}

public struct DoctorCheck: Codable, Equatable, Sendable {
    public let code: DoctorCheckCode
    public let status: DoctorCheckStatus
    public let errorCode: StableErrorCode?

    public init(
        code: DoctorCheckCode,
        status: DoctorCheckStatus,
        errorCode: StableErrorCode? = nil
    ) {
        self.code = code
        self.status = status
        self.errorCode = errorCode
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case status
        case errorCode = "error_code"
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let checks: [DoctorCheck]

    public init(checks: [DoctorCheck]) {
        self.schemaVersion = 1
        self.checks = checks
    }

    public var exitCode: Int32 {
        checks.contains { $0.status == .failed } ? 1 : 0
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case checks
    }
}
