import Foundation
import Testing

@testable import IrodoriVoiceChangerCLI
@testable import IrodoriVoiceChangerCore

@Suite("CLITests")
struct CLITests {
    @Test
    func shadowMonitorFactoryFollowsCommitMode() {
        let recorder = NoopTelemetryRecorder()
        let clock = SystemMonotonicClock()
        let finalOnly = CommitPolicyConfiguration(
            mode: .finalOnly,
            minimumObservations: 3,
            minimumStableMilliseconds: 400
        )
        let stablePrefix = CommitPolicyConfiguration(
            mode: .stablePrefix,
            minimumObservations: 3,
            minimumStableMilliseconds: 400
        )

        #expect(
            CLIApplication.shadowMonitor(
                finalOnly, UUID(), recorder, clock
            ) == nil)
        #expect(
            CLIApplication.shadowMonitor(
                stablePrefix, UUID(), recorder, clock
            ) != nil)
    }

    @Test
    func endpointShadowFactoryForwardsCandidateHandler() async throws {
        let handler = CLIEndpointCandidateHandlerSpy()
        let queue = try #require(
            CLIApplication.endpointShadowQueue(
                100,
                UUID(),
                NoopTelemetryRecorder(),
                SystemMonotonicClock(),
                candidateHandler: handler
            ))
        let utteranceID = UUID()

        queue.start()
        queue.observe(.speechStarted(utteranceID))
        queue.observe(.partial(utteranceID, text: "候補", revisionCount: 0))
        queue.observeAudio(isSpeech: false, durationMilliseconds: 100)
        await queue.stop()

        #expect(await handler.utteranceIDs == [utteranceID])
    }

    @Test
    func replayEndpointFailurePreservesPipelineError() async {
        let sessionID = UUID()
        let recorder = NoopTelemetryRecorder()
        let clock = SystemMonotonicClock()
        let handler = EndpointFinalizationHandler(
            sessionID: sessionID,
            telemetry: recorder,
            clock: clock,
            operation: { throw CLIEndpointTestError.failed }
        )
        _ = await handler.handleEndpointCandidate(utteranceID: UUID())
        let events = AsyncThrowingStream<SpeechEvent, Error> { $0.finish() }

        await #expect(throws: PipelineOperationError(.speechUnavailable)) {
            try await CLIApplication.consumeSpeechOnlyReplay(
                events: events,
                shadow: nil,
                endpoint: .init(
                    finalizationHandler: handler,
                    semanticHandler: nil,
                    queue: nil
                ),
                recorder: recorder,
                clock: clock,
                sessionID: sessionID
            )
        }
    }

    @Test
    func liveSmartTurnShadowKeepsCompleteDecisionNonTerminal() async throws {
        let handler = try #require(
            CLIApplication.makeLiveSemanticHandler(
                options: .init(
                    showTranscript: false,
                    shadowSynthesizePrefix: false,
                    endpointShadowMilliseconds: nil,
                    shadowSmartTurn: true
                ),
                classifier: CLISemanticClassifierStub(
                    prediction: try SemanticTurnPrediction(
                        probability: 0.9,
                        durationMilliseconds: 5
                    )
                ),
                sessionID: UUID(),
                recorder: NoopTelemetryRecorder(),
                clock: SystemMonotonicClock()
            )
        )

        let disposition = await handler.handleEndpointCandidate(utteranceID: UUID())

        #expect(disposition == .retryAfterSpeech)
    }

    @Test
    func liveSmartTurnShadowUsesSevenHundredMilliseconds() {
        #expect(
            CLIApplication.liveEndpointMilliseconds(
                options: .init(
                    showTranscript: false,
                    shadowSynthesizePrefix: false,
                    endpointShadowMilliseconds: nil,
                    shadowSmartTurn: true
                )
            ) == 700
        )
    }

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
                == .run(
                    path: nil,
                    showTranscript: true,
                    shadowSynthesizePrefix: false,
                    endpointShadowMilliseconds: nil,
                    shadowSmartTurn: false
                )
        )
        #expect(
            try CLIParser.parse(["run", "--shadow-synthesize-prefix"])
                == .run(
                    path: nil,
                    showTranscript: false,
                    shadowSynthesizePrefix: true,
                    endpointShadowMilliseconds: nil,
                    shadowSmartTurn: false
                )
        )
        #expect(
            try CLIParser.parse(["run", "--shadow-endpoint-ms", "300"])
                == .run(
                    path: nil,
                    showTranscript: false,
                    shadowSynthesizePrefix: false,
                    endpointShadowMilliseconds: 300,
                    shadowSmartTurn: false
                )
        )
        #expect(
            try CLIParser.parse(["run", "--shadow-smart-turn"])
                == .run(
                    path: nil,
                    showTranscript: false,
                    shadowSynthesizePrefix: false,
                    endpointShadowMilliseconds: nil,
                    shadowSmartTurn: true
                )
        )
        #expect(throws: CLIUsageError.self) {
            try CLIParser.parse(["run", "--smart-turn-finalize"])
        }
        #expect(
            try CLIParser.parse(["report", "latest", "--json"])
                == .report(session: "latest", path: nil, json: true)
        )
    }

    @Test
    func parsesDocumentedReplayCommands() throws {
        #expect(
            try CLIParser.parse([
                "replay", "/tmp/input.wav", "--synthesize", "--live-output",
            ])
                == .replay(
                    input: "/tmp/input.wav",
                    path: nil,
                    synthesize: true,
                    liveOutput: true,
                    shadowSynthesizePrefix: false,
                    endpointShadowMilliseconds: nil,
                    earlyFinalizeShadowMilliseconds: nil,
                    smartTurnShadow: false
                )
        )
        #expect(
            try CLIParser.parse([
                "replay", "/tmp/input.wav", "--synthesize", "--shadow-synthesize-prefix",
            ])
                == .replay(
                    input: "/tmp/input.wav",
                    path: nil,
                    synthesize: true,
                    liveOutput: false,
                    shadowSynthesizePrefix: true,
                    endpointShadowMilliseconds: nil,
                    earlyFinalizeShadowMilliseconds: nil,
                    smartTurnShadow: false
                )
        )
        #expect(
            try CLIParser.parse([
                "replay", "/tmp/input.wav", "--shadow-endpoint-ms", "700",
            ])
                == .replay(
                    input: "/tmp/input.wav",
                    path: nil,
                    synthesize: false,
                    liveOutput: false,
                    shadowSynthesizePrefix: false,
                    endpointShadowMilliseconds: 700,
                    earlyFinalizeShadowMilliseconds: nil,
                    smartTurnShadow: false
                )
        )
        #expect(
            try CLIParser.parse([
                "replay", "/tmp/input.wav", "--shadow-early-finalize-ms", "300",
            ])
                == .replay(
                    input: "/tmp/input.wav",
                    path: nil,
                    synthesize: false,
                    liveOutput: false,
                    shadowSynthesizePrefix: false,
                    endpointShadowMilliseconds: nil,
                    earlyFinalizeShadowMilliseconds: 300,
                    smartTurnShadow: false
                )
        )
        #expect(
            try CLIParser.parse(["replay", "/tmp/input.wav", "--shadow-smart-turn"])
                == .replay(
                    input: "/tmp/input.wav",
                    path: nil,
                    synthesize: false,
                    liveOutput: false,
                    shadowSynthesizePrefix: false,
                    endpointShadowMilliseconds: nil,
                    earlyFinalizeShadowMilliseconds: nil,
                    smartTurnShadow: true
                )
        )
    }

    @Test(arguments: [
        ["run", "--shadow-endpoint-ms"],
        ["run", "--shadow-endpoint-ms", "invalid"],
        ["run", "--shadow-endpoint-ms", "99"],
        ["run", "--shadow-endpoint-ms", "3001"],
        ["run", "--shadow-endpoint-ms", "300", "--shadow-endpoint-ms", "500"],
    ])
    func endpointShadowRequiresOneBoundedInteger(_ arguments: [String]) {
        #expect(throws: CLIUsageError.self) {
            try CLIParser.parse(arguments)
        }
    }

    @Test(arguments: [
        ["replay", "/tmp/input.wav", "--shadow-early-finalize-ms"],
        ["replay", "/tmp/input.wav", "--shadow-early-finalize-ms", "invalid"],
        ["replay", "/tmp/input.wav", "--shadow-early-finalize-ms", "99"],
        ["replay", "/tmp/input.wav", "--shadow-early-finalize-ms", "3001"],
        [
            "replay", "/tmp/input.wav", "--shadow-early-finalize-ms", "300",
            "--synthesize",
        ],
        [
            "replay", "/tmp/input.wav", "--shadow-early-finalize-ms", "300",
            "--live-output", "--synthesize",
        ],
        [
            "replay", "/tmp/input.wav", "--shadow-early-finalize-ms", "300",
            "--shadow-synthesize-prefix", "--synthesize",
        ],
        [
            "replay", "/tmp/input.wav", "--shadow-early-finalize-ms", "300",
            "--shadow-endpoint-ms", "300",
        ],
    ])
    func earlyFinalizeShadowIsReplayOnlySpeechOnlyAndBounded(_ arguments: [String]) {
        #expect(throws: CLIUsageError.self) {
            try CLIParser.parse(arguments)
        }
    }

    @Test(arguments: [
        ["run", "--shadow-smart-turn", "--shadow-endpoint-ms", "700"],
        ["run", "--shadow-smart-turn", "--shadow-synthesize-prefix"],
        ["replay", "/tmp/input.wav", "--shadow-smart-turn", "--synthesize"],
        ["replay", "/tmp/input.wav", "--shadow-smart-turn", "--live-output"],
        ["replay", "/tmp/input.wav", "--shadow-smart-turn", "--shadow-synthesize-prefix"],
        ["replay", "/tmp/input.wav", "--shadow-smart-turn", "--shadow-endpoint-ms", "700"],
        [
            "replay", "/tmp/input.wav", "--shadow-smart-turn",
            "--shadow-early-finalize-ms", "700",
        ],
        ["replay", "/tmp/input.wav", "--smart-turn-finalize"],
    ])
    func smartTurnOptionsAreMutuallyExclusiveWithExistingEndpointExperiments(
        _ arguments: [String]
    ) {
        #expect(throws: CLIUsageError.self) {
            try CLIParser.parse(arguments)
        }
    }

    @Test
    func shadowSynthesisRequiresSynthesisAndStablePrefixMode() throws {
        #expect(throws: CLIUsageError.self) {
            try CLIParser.parse(["replay", "/tmp/input.wav", "--shadow-synthesize-prefix"])
        }
        #expect(throws: CLIUsageError.self) {
            try CLIApplication.validateShadowSynthesis(
                enabled: true,
                policy: CommitPolicyConfiguration(
                    mode: .finalOnly,
                    minimumObservations: 3,
                    minimumStableMilliseconds: 400
                )
            )
        }
        #expect(throws: Never.self) {
            try CLIApplication.validateShadowSynthesis(
                enabled: true,
                policy: CommitPolicyConfiguration(
                    mode: .stablePrefix,
                    minimumObservations: 3,
                    minimumStableMilliseconds: 400
                )
            )
        }
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

private enum CLIEndpointTestError: Error {
    case failed
}

private actor NoopTelemetryRecorder: TelemetryRecording {
    func record(_: TelemetryEvent) -> TelemetryWriteResult {
        .written
    }
}

private actor CLIEndpointCandidateHandlerSpy: EndpointCandidateHandling {
    private(set) var utteranceIDs = [UUID]()

    func handleEndpointCandidate(utteranceID: UUID) -> EndpointCandidateDisposition {
        utteranceIDs.append(utteranceID)
        return .terminal
    }
}

private struct CLISemanticClassifierStub: SemanticTurnClassifying {
    let prediction: SemanticTurnPrediction

    func predict(samples _: [Float], sampleRate _: Double) -> SemanticTurnPrediction {
        prediction
    }
}
