import Foundation
import IrodoriVoiceChangerCore
import Testing

@testable import IrodoriVoiceChangerCLI

@Suite("CLITests")
struct CLITests {
    @Test
    func parsesDocumentedCommands() throws {
        #expect(try CLIParser.parse(["devices"]) == .devices)
        #expect(try CLIParser.parse(["config", "init"]) == .configInit(path: nil))
        #expect(
            try CLIParser.parse(["config", "validate", "--path", "/tmp/config.json"])
                == .configValidate(path: "/tmp/config.json")
        )
        #expect(
            try CLIParser.parse(["doctor", "--synthesize", "--path", "/tmp/config.json"])
                == .doctor(path: "/tmp/config.json", synthesize: true)
        )
        #expect(
            try CLIParser.parse(["run", "--show-transcript"])
                == .run(path: nil, showTranscript: true)
        )
        #expect(
            try CLIParser.parse([
                "replay", "/tmp/input.wav", "--synthesize", "--live-output",
            ])
                == .replay(
                    input: "/tmp/input.wav",
                    path: nil,
                    synthesize: true,
                    liveOutput: true
                )
        )
        #expect(
            try CLIParser.parse(["report", "latest", "--json"])
                == .report(session: "latest", path: nil, json: true)
        )
    }

    @Test(arguments: [
        [String](),
        ["unknown"],
        ["config"],
        ["config", "delete"],
        ["doctor", "--unknown"],
        ["run", "--path"],
        ["replay"],
        ["devices", "extra"],
    ])
    func rejectsUnknownOrIncompleteArguments(_ arguments: [String]) {
        #expect(throws: CLIUsageError.self) {
            try CLIParser.parse(arguments)
        }
    }

    @Test
    func helpIsExplicit() throws {
        #expect(try CLIParser.parse(["help"]) == .help)
        #expect(try CLIParser.parse(["--help"]) == .help)
        #expect(CLIUsageError.exitCode == 64)
    }

    @Test
    func defaultConfigurationIsIndependentOfWorkingDirectory() {
        let url = CLIApplication.configurationURL(nil)

        #expect(url.path.hasSuffix("/Library/Application Support/IrodoriVoiceChanger/config.json"))
        #expect(!url.path.hasSuffix("/config/irodori-voicechanger.json"))
    }

    @Test
    func doctorProbeEventsUseOneCorrelationIDForLatencyReporting() {
        let sessionID = UUID()
        let probeID = UUID()
        let factory = DoctorProbeEventFactory(sessionID: sessionID, probeID: probeID)
        let events = [
            factory.requestStarted(timestamp: 100),
            factory.milestone(.handshake, timestamp: 120, requestStarted: 100),
            factory.milestone(.firstAudioPayload, timestamp: 140, requestStarted: 100),
            factory.milestone(
                .completed(serverElapsedMilliseconds: 30, samplingSteps: 12),
                timestamp: 150,
                requestStarted: 100
            ),
            TelemetryEvent(
                sessionID: sessionID,
                utteranceID: nil,
                timestampNanoseconds: 160,
                name: .sessionStopped,
                stage: .lifecycle
            ),
        ]

        #expect(events.dropLast().allSatisfy { $0.utteranceID == probeID })
        let report = TelemetryReportBuilder.build(events: events, sessionID: sessionID)
        #expect(report.metrics[.requestToFirstAudio]?.p50 == 0.000_04)
    }
}
