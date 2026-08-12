import AVFAudio
import Foundation
import Testing

@testable import IrodoriVoiceChangerMacOS

@Suite("MicrophoneCaptureTests")
struct MicrophoneCaptureTests {
    @Test
    func tapHandlerCanRunOutsideTheMainExecutor() async throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1,
                interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16
        let invoked = LockedFlag()
        let handler = SendableTapHandler(
            makeMicrophoneTapHandler { _ in
                invoked.set()
            })
        let sendableBuffer = SendableAudioBuffer(buffer)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "microphone-capture-test").async {
                handler.value(sendableBuffer.value, AVAudioTime())
                continuation.resume()
            }
        }

        #expect(invoked.value)
    }
}

private struct SendableTapHandler: @unchecked Sendable {
    let value: AVAudioNodeTapBlock

    init(_ value: @escaping AVAudioNodeTapBlock) {
        self.value = value
    }
}

private struct SendableAudioBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer

    init(_ value: AVAudioPCMBuffer) {
        self.value = value
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.withLock { storedValue }
    }

    func set() {
        lock.withLock { storedValue = true }
    }
}
