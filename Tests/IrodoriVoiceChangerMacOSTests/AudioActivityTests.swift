import AVFAudio
import Testing

@testable import IrodoriVoiceChangerMacOS

@Suite("AudioActivityTests")
struct AudioActivityTests {
    @Test
    func floatBufferAboveFixedThresholdIsSpeech() throws {
        let buffer = try makeFloatBuffer(amplitude: 0.1, frames: 480)

        let sample = try #require(AudioActivity.sample(from: buffer))

        #expect(sample.isSpeech)
        #expect(abs(sample.durationMilliseconds - 10) < 0.001)
        #expect(sample.sampleRate == 48_000)
        #expect(sample.samples == Array(repeating: 0.1, count: 480))
    }

    @Test
    func nonInterleavedFloatStereoIsMixedToMono() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 2,
                interleaved: false
            ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let channels = try #require(buffer.floatChannelData)
        channels[0][0] = 0.2
        channels[0][1] = 0.4
        channels[0][2] = 0.6
        channels[1][0] = 0.0
        channels[1][1] = 0.2
        channels[1][2] = 0.4

        let sample = try #require(AudioActivity.sample(from: buffer))

        #expect(sample.samples.elementsEqual([0.1, 0.3, 0.5]) { abs($0 - $1) < 0.000_1 })
        #expect(sample.sampleRate == 16_000)
    }

    @Test
    func interleavedInt16StereoIsNormalizedAndMixedToMono() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 2,
                interleaved: true
            ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let values = try #require(
            buffer.mutableAudioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(
                to: Int16.self)
        )
        values[0] = 16_384
        values[1] = 0
        values[2] = 8_192
        values[3] = 8_192
        buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = 8

        let sample = try #require(AudioActivity.sample(from: buffer))

        #expect(sample.samples == [0.25, 0.25])
        #expect(sample.isSpeech)
    }

    @Test
    func silenceAndLowLevelBufferAreNotSpeech() throws {
        let silence = try makeFloatBuffer(amplitude: 0, frames: 480)
        let lowLevel = try makeFloatBuffer(amplitude: 0.001, frames: 480)

        #expect(AudioActivity.sample(from: silence)?.isSpeech == false)
        #expect(AudioActivity.sample(from: lowLevel)?.isSpeech == false)
    }

    private func makeFloatBuffer(
        amplitude: Float,
        frames: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            ))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = amplitude
        }
        return buffer
    }
}
