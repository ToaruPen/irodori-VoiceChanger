import AVFAudio
import Foundation
import IrodoriVoiceChangerCore
import Speech

public enum AudioFileReplay {
    public static func inputs(
        from url: URL,
        analysisFormat: AVAudioFormat,
        maximumBytes: Int,
        maximumDurationSeconds: Double,
        chunkFrames: Int = 2_048,
        paced: Bool = true
    ) throws -> AsyncStream<AnalyzerInput> {
        let wave = try PCM16Wave.decode(
            Data(contentsOf: url, options: .mappedIfSafe),
            maximumBytes: maximumBytes,
            maximumDurationSeconds: maximumDurationSeconds
        )
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(wave.sampleRate),
                channels: AVAudioChannelCount(wave.channelCount),
                interleaved: true
            )
        else {
            throw WAVError.unsupportedFormat
        }
        let converter = AVAudioConverter(from: sourceFormat, to: analysisFormat)
        // The decoded input is already bounded by maximumBytes and maximumDurationSeconds.
        // Dropping old buffers would erase the beginning of an utterance before analysis starts.
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached {
                let bytesPerFrame = wave.channelCount * 2
                var frameOffset = 0
                while frameOffset < wave.frameCount, !Task.isCancelled {
                    let count = min(chunkFrames, wave.frameCount - frameOffset)
                    guard
                        let source = AVAudioPCMBuffer(
                            pcmFormat: sourceFormat,
                            frameCapacity: AVAudioFrameCount(count)
                        ),
                        let destination = source.mutableAudioBufferList.pointee.mBuffers.mData
                    else {
                        break
                    }
                    source.frameLength = AVAudioFrameCount(count)
                    let byteOffset = frameOffset * bytesPerFrame
                    let byteCount = count * bytesPerFrame
                    wave.pcmBytes.copyBytes(
                        to: destination.assumingMemoryBound(to: UInt8.self),
                        from: byteOffset..<(byteOffset + byteCount)
                    )
                    source.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(byteCount)
                    if sourceFormat == analysisFormat {
                        continuation.yield(AnalyzerInput(buffer: source))
                    } else if let converter,
                        let converted = source.convertedForReplay(
                            using: converter,
                            to: analysisFormat)
                    {
                        continuation.yield(AnalyzerInput(buffer: converted))
                    }
                    frameOffset += count
                    if paced {
                        let seconds = Double(count) / Double(wave.sampleRate)
                        try? await Task.sleep(for: .seconds(seconds))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension AVAudioPCMBuffer {
    func convertedForReplay(using converter: AVAudioConverter, to format: AVAudioFormat)
        -> AVAudioPCMBuffer?
    {
        let ratio = format.sampleRate / self.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        let provider = ReplayConversionInputProvider(buffer: self)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            provider.next(status: inputStatus)
        }
        guard conversionError == nil,
            status == .haveData || status == .inputRanDry,
            output.frameLength > 0
        else {
            return nil
        }
        return output
    }
}

private final class ReplayConversionInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
}
