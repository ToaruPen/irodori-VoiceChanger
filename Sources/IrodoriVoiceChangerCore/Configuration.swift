import Foundation

public enum SamplingSchedule: String, Codable, Sendable {
    case linear
    case sway
}

public enum IrodoriStyle: String, Codable, Sendable {
    case neutral
    case calm
    case cheerful
    case clear
}

public enum DetectorSensitivity: String, Codable, Sendable {
    case low
    case medium
    case high
}

public enum CommitMode: String, Codable, Sendable {
    case finalOnly = "final_only"
    case stablePrefix = "stable_prefix"
}

public struct IrodoriConfiguration: Codable, Equatable, Sendable {
    public let baseURL: URL
    public let voiceID: String?
    public let numSteps: Int
    public let schedule: SamplingSchedule
    public let style: IrodoriStyle
    public let swayCoefficient: Double

    private enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case voiceID = "voice_id"
        case numSteps = "num_steps"
        case schedule
        case style
        case swayCoefficient = "sway_coefficient"
    }
}

public struct AudioConfiguration: Codable, Equatable, Sendable {
    public let outputDeviceUID: String
    public let maximumWAVBytes: Int
    public let maximumClipSeconds: Double

    private enum CodingKeys: String, CodingKey {
        case outputDeviceUID = "output_device_uid"
        case maximumWAVBytes = "maximum_wav_bytes"
        case maximumClipSeconds = "maximum_clip_seconds"
    }
}

public struct CommitPolicyConfiguration: Codable, Equatable, Sendable {
    public let mode: CommitMode
    public let minimumObservations: Int
    public let minimumStableMilliseconds: Int

    private enum CodingKeys: String, CodingKey {
        case mode
        case minimumObservations = "minimum_observations"
        case minimumStableMilliseconds = "minimum_stable_milliseconds"
    }
}

public struct SpeechConfiguration: Codable, Equatable, Sendable {
    public let localeIdentifier: String
    public let detectorSensitivity: DetectorSensitivity
    public let inputBufferFrames: Int
    public let commitPolicy: CommitPolicyConfiguration

    private enum CodingKeys: String, CodingKey {
        case localeIdentifier = "locale_identifier"
        case detectorSensitivity = "detector_sensitivity"
        case inputBufferFrames = "input_buffer_frames"
        case commitPolicy = "commit_policy"
    }
}

public struct QueueConfiguration: Codable, Equatable, Sendable {
    public let pendingSynthesis: Int
    public let pendingPlayback: Int

    private enum CodingKeys: String, CodingKey {
        case pendingSynthesis = "pending_synthesis"
        case pendingPlayback = "pending_playback"
    }
}

public struct TelemetryConfiguration: Codable, Equatable, Sendable {
    public let directory: String
    public let maximumFileBytes: Int
    public let retainedFileCount: Int

    private enum CodingKeys: String, CodingKey {
        case directory
        case maximumFileBytes = "maximum_file_bytes"
        case retainedFileCount = "retained_file_count"
    }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let irodori: IrodoriConfiguration
    public let audio: AudioConfiguration
    public let speech: SpeechConfiguration
    public let queues: QueueConfiguration
    public let telemetry: TelemetryConfiguration

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case irodori
        case audio
        case speech
        case queues
        case telemetry
    }
}

public enum ConfigurationError: Error, Equatable, Sendable {
    case invalidJSON
    case unknownKey
    case invalidSchemaVersion
    case invalidValue
}

public enum ConfigurationLoader {
    public static func decode(_ data: Data) throws -> AppConfiguration {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConfigurationError.invalidJSON
        }
        try validateKeys(object)

        let configuration: AppConfiguration
        do {
            configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
        } catch {
            throw ConfigurationError.invalidJSON
        }
        try validate(configuration)
        return configuration
    }

    public static func load(from url: URL) throws -> AppConfiguration {
        try decode(Data(contentsOf: url))
    }

    private static func validateKeys(_ object: Any) throws {
        guard let root = object as? [String: Any] else {
            throw ConfigurationError.invalidJSON
        }
        try requireKeys(
            root,
            allowed: ["schema_version", "irodori", "audio", "speech", "queues", "telemetry"]
        )
        try requireNestedKeys(
            root["irodori"],
            allowed: ["base_url", "voice_id", "num_steps", "schedule", "style", "sway_coefficient"]
        )
        try requireNestedKeys(
            root["audio"],
            allowed: ["output_device_uid", "maximum_wav_bytes", "maximum_clip_seconds"]
        )
        try requireNestedKeys(
            root["speech"],
            allowed: [
                "locale_identifier", "detector_sensitivity", "input_buffer_frames", "commit_policy",
            ]
        )
        try requireNestedKeys(
            (root["speech"] as? [String: Any])?["commit_policy"],
            allowed: ["mode", "minimum_observations", "minimum_stable_milliseconds"]
        )
        try requireNestedKeys(
            root["queues"],
            allowed: ["pending_synthesis", "pending_playback"]
        )
        try requireNestedKeys(
            root["telemetry"],
            allowed: ["directory", "maximum_file_bytes", "retained_file_count"]
        )
    }

    private static func requireNestedKeys(_ object: Any?, allowed: Set<String>) throws {
        guard let dictionary = object as? [String: Any] else {
            throw ConfigurationError.invalidJSON
        }
        try requireKeys(dictionary, allowed: allowed)
    }

    private static func requireKeys(_ dictionary: [String: Any], allowed: Set<String>) throws {
        guard Set(dictionary.keys).isSubset(of: allowed) else {
            throw ConfigurationError.unknownKey
        }
    }

    private static func validate(_ configuration: AppConfiguration) throws {
        guard configuration.schemaVersion == 1 else {
            throw ConfigurationError.invalidSchemaVersion
        }
        try validateIrodori(configuration.irodori)
        try validateAudio(configuration.audio)
        try validateSpeech(configuration.speech)
        guard (1...64).contains(configuration.queues.pendingSynthesis),
            (1...64).contains(configuration.queues.pendingPlayback)
        else {
            throw ConfigurationError.invalidValue
        }
        guard !configuration.telemetry.directory.trimmingCharacters(in: .whitespaces).isEmpty,
            (1_024...52_428_800).contains(configuration.telemetry.maximumFileBytes),
            (1...10).contains(configuration.telemetry.retainedFileCount)
        else {
            throw ConfigurationError.invalidValue
        }
    }

    private static func validateIrodori(_ configuration: IrodoriConfiguration) throws {
        guard (1...64).contains(configuration.numSteps), configuration.swayCoefficient.isFinite
        else {
            throw ConfigurationError.invalidValue
        }
        if let voiceID = configuration.voiceID,
            voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw ConfigurationError.invalidValue
        }
        guard
            let components = URLComponents(
                url: configuration.baseURL, resolvingAgainstBaseURL: false),
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty || components.path == "/",
            let scheme = components.scheme?.lowercased(),
            let rawHost = components.host?.lowercased()
        else {
            throw ConfigurationError.invalidValue
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let secureRemote = scheme == "https"
        let numericLoopback = scheme == "http" && (host == "127.0.0.1" || host == "::1")
        guard secureRemote || numericLoopback else {
            throw ConfigurationError.invalidValue
        }
    }

    private static func validateAudio(_ configuration: AudioConfiguration) throws {
        guard
            !configuration.outputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (1_048_576...134_217_728).contains(configuration.maximumWAVBytes),
            configuration.maximumClipSeconds > 0,
            configuration.maximumClipSeconds <= 120,
            configuration.maximumClipSeconds.isFinite
        else {
            throw ConfigurationError.invalidValue
        }
    }

    private static func validateSpeech(_ configuration: SpeechConfiguration) throws {
        let bufferFrames = configuration.inputBufferFrames
        guard
            !configuration.localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (128...8_192).contains(bufferFrames),
            bufferFrames.nonzeroBitCount == 1,
            (2...10).contains(configuration.commitPolicy.minimumObservations),
            (50...5_000).contains(configuration.commitPolicy.minimumStableMilliseconds)
        else {
            throw ConfigurationError.invalidValue
        }
    }
}
