import Foundation

@testable import IrodoriVoiceChangerCore

actor PlaybackStartGatingRecorder: TelemetryRecording {
    private(set) var events = [TelemetryEvent]()
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var playbackStartBlocked = false

    func record(_ event: TelemetryEvent) async -> TelemetryWriteResult {
        events.append(event)
        if event.name == .playbackStarted {
            playbackStartBlocked = true
            blockedContinuation?.resume()
            blockedContinuation = nil
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return .written
    }

    func waitUntilPlaybackStartIsBlocked() async {
        guard !playbackStartBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedContinuation = continuation
        }
    }

    func releasePlaybackStart() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
