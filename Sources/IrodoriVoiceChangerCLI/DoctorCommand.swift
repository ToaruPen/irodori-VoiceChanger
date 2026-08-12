import Foundation
import IrodoriVoiceChangerCore
import IrodoriVoiceChangerMacOS

extension CLIApplication {
    static func runDoctor(path: String?, synthesize: Bool) async -> DoctorReport {
        var checks = [DoctorCheck(code: .operatingSystem, status: .passed)]
        let configuration: AppConfiguration
        do {
            configuration = try loadConfiguration(path: path)
            checks.append(.init(code: .configuration, status: .passed))
        } catch {
            checks.append(
                .init(code: .configuration, status: .failed, errorCode: .invalidConfiguration))
            return DoctorReport(checks: checks)
        }
        let telemetry = synthesize ? DoctorTelemetry(configuration: configuration) : nil
        await telemetry?.start()
        checks.append(permissionCheck(.microphonePermission, state: AppPermissions.microphone))
        await appendSpeechChecks(configuration: configuration, to: &checks)
        appendOutputCheck(configuration: configuration, to: &checks)
        await appendIrodoriChecks(
            configuration: configuration,
            synthesize: synthesize,
            telemetry: telemetry,
            to: &checks
        )
        await telemetry?.stop()
        return DoctorReport(checks: checks)
    }

    private static func appendSpeechChecks(
        configuration: AppConfiguration,
        to checks: inout [DoctorCheck]
    ) async {
        let inspection = await AppleSpeechSession.inspect(
            localeIdentifier: configuration.speech.localeIdentifier,
            sensitivity: configuration.speech.detectorSensitivity
        )
        checks.append(
            .init(
                code: .speechLocale,
                status: inspection.localeSupported ? .passed : .failed,
                errorCode: inspection.localeSupported ? nil : .speechUnavailable
            ))
        switch inspection.assetState {
        case .installed:
            checks.append(.init(code: .speechAsset, status: .passed))
        case .supported, .downloading:
            checks.append(.init(code: .speechAsset, status: .attention))
        case .unsupported:
            checks.append(.init(code: .speechAsset, status: .failed, errorCode: .speechUnavailable))
        }
    }

    private static func appendOutputCheck(
        configuration: AppConfiguration,
        to checks: inout [DoctorCheck]
    ) {
        do {
            _ = try AudioDeviceCatalog.current().resolveOutput(
                uid: configuration.audio.outputDeviceUID)
            checks.append(.init(code: .outputDevice, status: .passed))
        } catch {
            checks.append(
                .init(code: .outputDevice, status: .failed, errorCode: .outputUnavailable))
        }
    }

    private static func appendIrodoriChecks(
        configuration: AppConfiguration,
        synthesize: Bool,
        telemetry: DoctorTelemetry?,
        to checks: inout [DoctorCheck]
    ) async {
        let client = IrodoriClient(baseURL: configuration.irodori.baseURL)
        do {
            _ = try await client.health()
            checks.append(.init(code: .irodoriReadiness, status: .passed))
            let voice = try await client.prepareVoice(
                configuredVoiceID: configuration.irodori.voiceID)
            checks.append(.init(code: .voiceResolution, status: .passed))
            guard synthesize else { return }
            let started = await telemetry?.requestStarted()
            let result = try await client.synthesize(
                text: "こんにちは。",
                voice: voice,
                profile: synthesisProfile(configuration),
                maximumBytes: configuration.audio.maximumWAVBytes,
                onMilestone: { await telemetry?.milestone($0, requestStarted: started) }
            )
            _ = try PCM16Wave.decode(
                result.wavBytes,
                maximumBytes: configuration.audio.maximumWAVBytes,
                maximumDurationSeconds: configuration.audio.maximumClipSeconds
            )
            checks.append(.init(code: .synthesisProbe, status: .passed))
        } catch let error as IrodoriClientError {
            let code = error.stableCode
            await telemetry?.failure(code)
            appendIrodoriFailure(code: code, synthesize: synthesize, to: &checks)
        } catch {
            await telemetry?.failure(.invalidResponse)
            checks.append(
                .init(code: .synthesisProbe, status: .failed, errorCode: .invalidResponse))
        }
    }

    private static func appendIrodoriFailure(
        code: StableErrorCode,
        synthesize: Bool,
        to checks: inout [DoctorCheck]
    ) {
        if !checks.contains(where: { $0.code == .irodoriReadiness }) {
            checks.append(.init(code: .irodoriReadiness, status: .failed, errorCode: code))
        } else if !checks.contains(where: { $0.code == .voiceResolution }) {
            checks.append(.init(code: .voiceResolution, status: .failed, errorCode: code))
        } else if synthesize {
            checks.append(.init(code: .synthesisProbe, status: .failed, errorCode: code))
        }
    }

    private static func permissionCheck(
        _ code: DoctorCheckCode,
        state: PermissionState
    ) -> DoctorCheck {
        switch state {
        case .authorized: .init(code: code, status: .passed)
        case .notDetermined: .init(code: code, status: .attention)
        case .denied, .restricted:
            .init(code: code, status: .failed, errorCode: .permissionDenied)
        }
    }
}

private actor DoctorTelemetry {
    private let recorder: SessionTelemetryRecorder
    private let clock = SystemMonotonicClock()
    private let sessionID = UUID()
    private let probeID = UUID()

    init(configuration: AppConfiguration) {
        recorder = CLIApplication.telemetryRecorder(configuration)
    }

    func start() async {
        await CLIApplication.recordSession(
            .sessionStarted, sessionID: sessionID, recorder: recorder, clock: clock)
    }

    func stop() async {
        await CLIApplication.recordSession(
            .sessionStopped, sessionID: sessionID, recorder: recorder, clock: clock)
    }

    func requestStarted() async -> UInt64 {
        let now = clock.nowNanoseconds()
        let factory = DoctorProbeEventFactory(sessionID: sessionID, probeID: probeID)
        _ = await recorder.record(factory.requestStarted(timestamp: now))
        return now
    }

    func milestone(_ milestone: SynthesisMilestone, requestStarted: UInt64?) async {
        let now = clock.nowNanoseconds()
        let factory = DoctorProbeEventFactory(sessionID: sessionID, probeID: probeID)
        _ = await recorder.record(
            factory.milestone(milestone, timestamp: now, requestStarted: requestStarted))
    }

    func failure(_ code: StableErrorCode) async {
        await CLIApplication.recordFailure(
            stage: .irodori,
            code: code,
            sessionID: sessionID,
            recorder: recorder,
            clock: clock
        )
    }
}
