import Foundation

@testable import IrodoriVoiceChangerCore

actor TwoStageGatePlayer: AudioPlaying {
    private var invocation = 0
    private var firstStartedContinuation: CheckedContinuation<Void, Never>?
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?
    private var secondStartedContinuation: CheckedContinuation<Void, Never>?
    private var secondReleaseContinuation: CheckedContinuation<Void, Never>?
    private var firstStarted = false
    private var secondStarted = false

    func play(_: AudioClip, utteranceID _: UUID) async throws {
        invocation += 1
        switch invocation {
        case 1:
            firstStarted = true
            firstStartedContinuation?.resume()
            firstStartedContinuation = nil
            await withCheckedContinuation { continuation in
                firstReleaseContinuation = continuation
            }
        case 2:
            secondStarted = true
            secondStartedContinuation?.resume()
            secondStartedContinuation = nil
            await withCheckedContinuation { continuation in
                secondReleaseContinuation = continuation
            }
        default:
            return
        }
    }

    func waitUntilFirstStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            firstStartedContinuation = continuation
        }
    }

    func waitUntilSecondStarted() async {
        guard !secondStarted else { return }
        await withCheckedContinuation { continuation in
            secondStartedContinuation = continuation
        }
    }

    func releaseFirst() {
        firstReleaseContinuation?.resume()
        firstReleaseContinuation = nil
    }

    func releaseSecond() {
        secondReleaseContinuation?.resume()
        secondReleaseContinuation = nil
    }
}
