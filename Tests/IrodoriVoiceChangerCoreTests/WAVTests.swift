import Foundation
import Testing

@testable import IrodoriVoiceChangerCore

@Suite("WAVTests")
struct WAVTests {
    @Test
    func parsesBoundedPCM16WaveAndComputesDuration() throws {
        let wave = makePCM16Wave(sampleRate: 48_000, channels: 1, samples: 48_000)

        let decoded = try PCM16Wave.decode(
            wave,
            maximumBytes: 200_000,
            maximumDurationSeconds: 2
        )

        #expect(decoded.sampleRate == 48_000)
        #expect(decoded.channelCount == 1)
        #expect(decoded.frameCount == 48_000)
        #expect(decoded.durationMilliseconds == 1_000)
        #expect(decoded.pcmBytes.count == 96_000)
    }

    @Test(arguments: [WaveMutation.truncated, .unsupportedEncoding, .misalignedData])
    func rejectsMalformedOrUnsupportedWave(_ mutation: WaveMutation) {
        var bytes = makePCM16Wave(sampleRate: 48_000, channels: 1, samples: 8)
        switch mutation {
        case .truncated:
            bytes.removeLast(4)
        case .unsupportedEncoding:
            bytes[20] = 3
        case .misalignedData:
            bytes.append(0)
            writeUInt32(UInt32(bytes.count - 8), into: &bytes, at: 4)
            writeUInt32(17, into: &bytes, at: 40)
        }

        #expect(throws: WAVError.self) {
            _ = try PCM16Wave.decode(
                bytes,
                maximumBytes: 1_024,
                maximumDurationSeconds: 2
            )
        }
    }

    @Test
    func byteAndDurationLimitsFailClosed() {
        let wave = makePCM16Wave(sampleRate: 48_000, channels: 1, samples: 48_000)

        #expect(throws: WAVError.tooLarge) {
            _ = try PCM16Wave.decode(wave, maximumBytes: 100, maximumDurationSeconds: 2)
        }
        #expect(throws: WAVError.tooLong) {
            _ = try PCM16Wave.decode(wave, maximumBytes: 200_000, maximumDurationSeconds: 0.5)
        }
    }

    @Test
    func rejectsOverflowingByteRateWithoutTrapping() {
        var wave = makePCM16Wave(sampleRate: 48_000, channels: 2, samples: 8)
        writeUInt32(.max, into: &wave, at: 24)
        writeUInt32(.max, into: &wave, at: 28)

        #expect(throws: WAVError.unsupportedFormat) {
            _ = try PCM16Wave.decode(
                wave,
                maximumBytes: 1_024,
                maximumDurationSeconds: 2
            )
        }
    }

    enum WaveMutation: Sendable {
        case truncated
        case unsupportedEncoding
        case misalignedData
    }
}

private func makePCM16Wave(sampleRate: UInt32, channels: UInt16, samples: Int) -> Data {
    let pcmCount = samples * Int(channels) * 2
    var data = Data(repeating: 0, count: 44 + pcmCount)
    data.replaceSubrange(0..<4, with: Data("RIFF".utf8))
    writeUInt32(UInt32(data.count - 8), into: &data, at: 4)
    data.replaceSubrange(8..<12, with: Data("WAVE".utf8))
    data.replaceSubrange(12..<16, with: Data("fmt ".utf8))
    writeUInt32(16, into: &data, at: 16)
    writeUInt16(1, into: &data, at: 20)
    writeUInt16(channels, into: &data, at: 22)
    writeUInt32(sampleRate, into: &data, at: 24)
    writeUInt32(sampleRate * UInt32(channels) * 2, into: &data, at: 28)
    writeUInt16(channels * 2, into: &data, at: 32)
    writeUInt16(16, into: &data, at: 34)
    data.replaceSubrange(36..<40, with: Data("data".utf8))
    writeUInt32(UInt32(pcmCount), into: &data, at: 40)
    return data
}

private func writeUInt16(_ value: UInt16, into data: inout Data, at offset: Int) {
    let bytes = [UInt8(value & 0xFF), UInt8(value >> 8)]
    data.replaceSubrange(offset..<(offset + 2), with: bytes)
}

private func writeUInt32(_ value: UInt32, into data: inout Data, at offset: Int) {
    let bytes = [
        UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF), UInt8(value >> 24),
    ]
    data.replaceSubrange(offset..<(offset + 4), with: bytes)
}
