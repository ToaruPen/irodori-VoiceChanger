import AVFAudio
import Foundation
import Testing

@testable import IrodoriVoiceChangerMacOS

@Suite("AudioFileReplayTests")
struct AudioFileReplayTests {
    @Test
    func replayObservesActivityWithoutDroppingAnalyzerFrames() async throws {
        let frameCount = 4_096
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeWave(frameCount: frameCount).write(to: url)
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            ))
        let collector = ActivityCollector()

        let inputs = try AudioFileReplay.inputs(
            from: url,
            analysisFormat: format,
            maximumBytes: 100_000,
            maximumDurationSeconds: 1,
            paced: false,
            activityObserver: { sample in collector.append(sample) }
        )
        var replayedFrames = 0
        for await input in inputs {
            replayedFrames += Int(input.buffer.frameLength)
        }

        #expect(replayedFrames == frameCount)
        #expect(collector.samples.count == 2)
        #expect(collector.samples.allSatisfy { !$0.isSpeech })
    }

    @Test
    func replayPreservesEveryFrameWhenProducerOutrunsConsumer() async throws {
        let frameCount = 2_048 * 100
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeWave(frameCount: frameCount).write(to: url)
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 48_000,
                channels: 1,
                interleaved: true
            ))

        let inputs = try AudioFileReplay.inputs(
            from: url,
            analysisFormat: format,
            maximumBytes: 1_000_000,
            maximumDurationSeconds: 10,
            paced: false
        )
        for _ in 0..<100 {
            await Task.yield()
        }
        var replayedFrames = 0
        for await input in inputs {
            replayedFrames += Int(input.buffer.frameLength)
        }

        #expect(replayedFrames == frameCount)
    }

    private func makeWave(frameCount: Int) -> Data {
        let pcmCount = frameCount * 2
        var data = Data(repeating: 0, count: 44 + pcmCount)
        data.replaceSubrange(0..<4, with: Data("RIFF".utf8))
        write(UInt32(data.count - 8), to: &data, at: 4)
        data.replaceSubrange(8..<12, with: Data("WAVEfmt ".utf8))
        write(UInt32(16), to: &data, at: 16)
        write(UInt16(1), to: &data, at: 20)
        write(UInt16(1), to: &data, at: 22)
        write(UInt32(48_000), to: &data, at: 24)
        write(UInt32(96_000), to: &data, at: 28)
        write(UInt16(2), to: &data, at: 32)
        write(UInt16(16), to: &data, at: 34)
        data.replaceSubrange(36..<40, with: Data("data".utf8))
        write(UInt32(pcmCount), to: &data, at: 40)
        return data
    }

    private func write(_ value: UInt16, to data: inout Data, at offset: Int) {
        data.replaceSubrange(
            offset..<(offset + 2),
            with: [UInt8(value & 0xFF), UInt8(value >> 8)]
        )
    }

    private func write(_ value: UInt32, to data: inout Data, at offset: Int) {
        data.replaceSubrange(
            offset..<(offset + 4),
            with: [
                UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF), UInt8(value >> 24),
            ]
        )
    }
}

private final class ActivityCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [AudioActivitySample]()

    var samples: [AudioActivitySample] {
        lock.withLock { storage }
    }

    func append(_ sample: AudioActivitySample) {
        lock.withLock { storage.append(sample) }
    }
}
