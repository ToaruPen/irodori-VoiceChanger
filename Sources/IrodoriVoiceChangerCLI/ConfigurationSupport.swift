import Foundation
import IrodoriVoiceChangerCore

extension CLIApplication {
    static func initializeConfiguration(path: String?) throws {
        let destination = configurationURL(path)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CLIExecutionError.configurationExists
        }
        let source = try exampleConfigurationURL()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }

    static func loadConfiguration(path: String?) throws -> AppConfiguration {
        try ConfigurationLoader.load(from: configurationURL(path))
    }

    static func loadRuntimeConfiguration(path: String?) async throws -> AppConfiguration {
        do {
            return try loadConfiguration(path: path)
        } catch {
            let recorder = defaultTelemetryRecorder()
            let clock = SystemMonotonicClock()
            let sessionID = UUID()
            await recordSession(
                .sessionStarted, sessionID: sessionID, recorder: recorder, clock: clock)
            _ = await recorder.record(
                TelemetryEvent(
                    sessionID: sessionID,
                    utteranceID: nil,
                    timestampNanoseconds: clock.nowNanoseconds(),
                    name: .operationFailed,
                    stage: .configuration,
                    errorCode: .invalidConfiguration
                ))
            await recordSession(
                .sessionStopped, sessionID: sessionID, recorder: recorder, clock: clock)
            throw error
        }
    }

    static func configurationURL(_ path: String?) -> URL {
        if let path {
            return URL(filePath: expand(path))
        }
        let base =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return
            base
            .appending(path: "IrodoriVoiceChanger", directoryHint: .isDirectory)
            .appending(path: "config.json")
    }

    static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private static func exampleConfigurationURL() throws -> URL {
        if let bundled = Bundle.main.url(
            forResource: "irodori-voicechanger.example",
            withExtension: "json"
        ) {
            return bundled
        }
        let local = URL(filePath: "config/irodori-voicechanger.example.json")
        guard FileManager.default.fileExists(atPath: local.path) else {
            throw CLIExecutionError.exampleConfigurationUnavailable
        }
        return local
    }
}
