import Foundation
import Testing

@testable import IrodoriVoiceChangerCore

@Suite("ConfigurationTests")
struct ConfigurationTests {
    @Test
    func completeConfigurationDecodes() throws {
        let configuration = try ConfigurationLoader.decode(Data(validJSON.utf8))

        #expect(configuration.schemaVersion == 1)
        #expect(configuration.irodori.baseURL.absoluteString == "https://voice.example.test")
        #expect(configuration.irodori.numSteps == 12)
        #expect(configuration.irodori.schedule == .sway)
        #expect(configuration.audio.outputDeviceUID == "BlackHole2ch_UID")
        #expect(configuration.speech.localeIdentifier == "ja-JP")
        #expect(configuration.speech.commitPolicy.mode == .finalOnly)
        #expect(configuration.queues.pendingSynthesis == 4)
        #expect(configuration.telemetry.retainedFileCount == 3)
    }

    @Test
    func unknownKeysFailClosed() {
        let json = validJSON.replacingOccurrences(
            of: #""schema_version": 1,"#,
            with: #""schema_version": 1, "unexpected": true,"#
        )

        #expect(throws: ConfigurationError.self) {
            try ConfigurationLoader.decode(Data(json.utf8))
        }
    }

    @Test(arguments: [0, 2])
    func unsupportedSchemaFails(_ schemaVersion: Int) {
        let json = validJSON.replacingOccurrences(
            of: #""schema_version": 1"#,
            with: #""schema_version": \#(schemaVersion)"#
        )

        #expect(throws: ConfigurationError.self) {
            try ConfigurationLoader.decode(Data(json.utf8))
        }
    }

    @Test(
        arguments: [
            "https://user:password@voice.example.test",
            "http://voice.example.test",
            "ftp://127.0.0.1:8924",
            "https://voice.example.test/path",
        ]
    )
    func unsafeBaseURLFails(_ baseURL: String) {
        let json = validJSON.replacingOccurrences(
            of: "https://voice.example.test",
            with: baseURL
        )

        #expect(throws: ConfigurationError.self) {
            try ConfigurationLoader.decode(Data(json.utf8))
        }
    }

    @Test(arguments: ["http://127.0.0.1:8924", "http://[::1]:8924"])
    func numericLoopbackHTTPIsAllowed(_ baseURL: String) throws {
        let json = validJSON.replacingOccurrences(
            of: "https://voice.example.test",
            with: baseURL
        )

        let configuration = try ConfigurationLoader.decode(Data(json.utf8))

        #expect(configuration.irodori.baseURL.scheme == "http")
    }

    @Test
    func blankOutputUIDFails() {
        let json = validJSON.replacingOccurrences(of: "BlackHole2ch_UID", with: "   ")

        #expect(throws: ConfigurationError.self) {
            try ConfigurationLoader.decode(Data(json.utf8))
        }
    }

    @Test
    func stablePrefixShadowModeDecodesWithItsThresholds() throws {
        let json = validJSON.replacingOccurrences(
            of: #""mode": "final_only""#,
            with: #""mode": "stable_prefix""#
        )

        let configuration = try ConfigurationLoader.decode(Data(json.utf8))

        #expect(configuration.speech.commitPolicy.mode == .stablePrefix)
        #expect(configuration.speech.commitPolicy.minimumObservations == 3)
        #expect(configuration.speech.commitPolicy.minimumStableMilliseconds == 400)
    }

    @Test(arguments: [0, 65])
    func samplingStepBoundsAreStrict(_ steps: Int) {
        let json = validJSON.replacingOccurrences(
            of: #""num_steps": 12"#,
            with: #""num_steps": \#(steps)"#
        )

        #expect(throws: ConfigurationError.self) {
            try ConfigurationLoader.decode(Data(json.utf8))
        }
    }

    @Test(arguments: [0, 65])
    func queueBoundsAreStrict(_ depth: Int) {
        let json = validJSON.replacingOccurrences(
            of: #""pending_synthesis": 4"#,
            with: #""pending_synthesis": \#(depth)"#
        )

        #expect(throws: ConfigurationError.self) {
            try ConfigurationLoader.decode(Data(json.utf8))
        }
    }

    @Test(arguments: [512, 52_428_801])
    func telemetryFileBoundsAreStrict(_ bytes: Int) {
        let json = validJSON.replacingOccurrences(
            of: #""maximum_file_bytes": 5242880"#,
            with: #""maximum_file_bytes": \#(bytes)"#
        )

        #expect(throws: ConfigurationError.self) {
            try ConfigurationLoader.decode(Data(json.utf8))
        }
    }

    private var validJSON: String {
        #"""
        {
          "schema_version": 1,
          "irodori": {
            "base_url": "https://voice.example.test",
            "voice_id": null,
            "num_steps": 12,
            "schedule": "sway",
            "style": "neutral",
            "sway_coefficient": -1.0
          },
          "audio": {
            "output_device_uid": "BlackHole2ch_UID",
            "maximum_wav_bytes": 67108864,
            "maximum_clip_seconds": 60.0
          },
          "speech": {
            "locale_identifier": "ja-JP",
            "detector_sensitivity": "medium",
            "input_buffer_frames": 1024,
            "commit_policy": {
              "mode": "final_only",
              "minimum_observations": 3,
              "minimum_stable_milliseconds": 400
            }
          },
          "queues": {
            "pending_synthesis": 4,
            "pending_playback": 4
          },
          "telemetry": {
            "directory": "~/Library/Application Support/IrodoriVoiceChanger/telemetry",
            "maximum_file_bytes": 5242880,
            "retained_file_count": 3
          }
        }
        """#
    }
}
