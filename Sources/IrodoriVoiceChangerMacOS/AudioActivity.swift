import AVFAudio
import Foundation

public struct AudioActivitySample: Equatable, Sendable {
    public let isSpeech: Bool
    public let durationMilliseconds: Double
    public let sampleRate: Double
    public let samples: [Float]

    public init(
        isSpeech: Bool,
        durationMilliseconds: Double,
        sampleRate: Double,
        samples: [Float]
    ) {
        self.isSpeech = isSpeech
        self.durationMilliseconds = durationMilliseconds
        self.sampleRate = sampleRate
        self.samples = samples
    }
}

public enum AudioActivity {
    public static let speechThresholdDecibels = -45.0

    public static func sample(from buffer: AVAudioPCMBuffer) -> AudioActivitySample? {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0,
            let meanSquare = meanSquareAmplitude(buffer),
            let samples = monoSamples(buffer)
        else {
            return nil
        }
        let decibels = meanSquare > 0 ? 10 * log10(meanSquare) : -.infinity
        return AudioActivitySample(
            isSpeech: decibels >= speechThresholdDecibels,
            durationMilliseconds: Double(buffer.frameLength) / buffer.format.sampleRate * 1_000,
            sampleRate: buffer.format.sampleRate,
            samples: samples
        )
    }

    private static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }
        if buffer.format.isInterleaved {
            return interleavedMonoSamples(
                buffers: buffers,
                format: buffer.format.commonFormat,
                frameCount: frameCount,
                channelCount: channelCount
            )
        }
        guard buffers.count >= channelCount else { return nil }
        return nonInterleavedMonoSamples(
            buffers: buffers,
            format: buffer.format.commonFormat,
            frameCount: frameCount,
            channelCount: channelCount
        )
    }

    private static func interleavedMonoSamples(
        buffers: UnsafeMutableAudioBufferListPointer,
        format: AVAudioCommonFormat,
        frameCount: Int,
        channelCount: Int
    ) -> [Float]? {
        guard let data = buffers.first?.mData else { return nil }
        var result = Array(repeating: Float.zero, count: frameCount)
        switch format {
        case .pcmFormatFloat32:
            let values = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    result[frame] += values[frame * channelCount + channel]
                }
                result[frame] /= Float(channelCount)
            }
        case .pcmFormatInt16:
            let values = data.assumingMemoryBound(to: Int16.self)
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    result[frame] += Float(values[frame * channelCount + channel]) / 32_768
                }
                result[frame] /= Float(channelCount)
            }
        default:
            return nil
        }
        return result
    }

    private static func nonInterleavedMonoSamples(
        buffers: UnsafeMutableAudioBufferListPointer,
        format: AVAudioCommonFormat,
        frameCount: Int,
        channelCount: Int
    ) -> [Float]? {
        var result = Array(repeating: Float.zero, count: frameCount)
        for channel in 0..<channelCount {
            guard let data = buffers[channel].mData else { return nil }
            switch format {
            case .pcmFormatFloat32:
                let values = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount {
                    result[frame] += values[frame] / Float(channelCount)
                }
            case .pcmFormatInt16:
                let values = data.assumingMemoryBound(to: Int16.self)
                for frame in 0..<frameCount {
                    result[frame] += Float(values[frame]) / 32_768 / Float(channelCount)
                }
            default:
                return nil
            }
        }
        return result
    }

    private static func meanSquareAmplitude(_ buffer: AVAudioPCMBuffer) -> Double? {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var sum = 0.0
        var count = 0
        for audioBuffer in buffers {
            guard let data = audioBuffer.mData else { continue }
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                let values = data.assumingMemoryBound(to: Float.self)
                let valueCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.stride
                for index in 0..<valueCount {
                    let value = Double(values[index])
                    sum += value * value
                }
                count += valueCount
            case .pcmFormatInt16:
                let values = data.assumingMemoryBound(to: Int16.self)
                let valueCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.stride
                for index in 0..<valueCount {
                    let value = Double(values[index]) / 32_768
                    sum += value * value
                }
                count += valueCount
            default:
                return nil
            }
        }
        guard count > 0 else { return nil }
        return sum / Double(count)
    }
}
