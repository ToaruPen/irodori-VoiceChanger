import Foundation

public enum WAVError: Error, Equatable, Sendable {
    case malformed
    case unsupportedFormat
    case tooLarge
    case tooLong
}

public struct PCM16Wave: Equatable, Sendable {
    public let sampleRate: Int
    public let channelCount: Int
    public let frameCount: Int
    public let pcmBytes: Data

    public var durationMilliseconds: Double {
        Double(frameCount) / Double(sampleRate) * 1_000
    }

    public static func decode(
        _ data: Data,
        maximumBytes: Int,
        maximumDurationSeconds: Double
    ) throws -> PCM16Wave {
        guard data.count <= maximumBytes else { throw WAVError.tooLarge }
        guard data.count >= 12,
            data.ascii(at: 0, count: 4) == "RIFF",
            data.ascii(at: 8, count: 4) == "WAVE",
            let riffSize = data.uint32LE(at: 4)
        else {
            throw WAVError.malformed
        }
        let declaredEnd = Int(riffSize) + 8
        guard declaredEnd <= data.count, declaredEnd >= 12 else { throw WAVError.malformed }

        var format: WaveFormat?
        var pcmBytes: Data?
        var offset = 12
        while offset + 8 <= declaredEnd {
            guard let chunkSizeValue = data.uint32LE(at: offset + 4) else {
                throw WAVError.malformed
            }
            let chunkSize = Int(chunkSizeValue)
            let payloadStart = offset + 8
            guard chunkSize <= declaredEnd - payloadStart else { throw WAVError.malformed }
            let payloadEnd = payloadStart + chunkSize
            switch data.ascii(at: offset, count: 4) {
            case "fmt ":
                guard format == nil, chunkSize >= 16,
                    let encoding = data.uint16LE(at: payloadStart),
                    let channels = data.uint16LE(at: payloadStart + 2),
                    let sampleRate = data.uint32LE(at: payloadStart + 4),
                    let byteRate = data.uint32LE(at: payloadStart + 8),
                    let blockAlign = data.uint16LE(at: payloadStart + 12),
                    let bitsPerSample = data.uint16LE(at: payloadStart + 14)
                else {
                    throw WAVError.malformed
                }
                let (expectedByteRate, overflowed) = sampleRate.multipliedReportingOverflow(
                    by: UInt32(blockAlign))
                guard encoding == 1, bitsPerSample == 16, (1...2).contains(channels),
                    sampleRate > 0,
                    blockAlign == channels * 2,
                    !overflowed,
                    byteRate == expectedByteRate
                else {
                    throw WAVError.unsupportedFormat
                }
                format = WaveFormat(
                    sampleRate: Int(sampleRate),
                    channels: Int(channels),
                    blockAlign: Int(blockAlign)
                )
            case "data":
                guard pcmBytes == nil else { throw WAVError.malformed }
                pcmBytes = Data(data[payloadStart..<payloadEnd])
            default:
                break
            }
            let padding = chunkSize % 2
            guard payloadEnd + padding <= declaredEnd else { throw WAVError.malformed }
            offset = payloadEnd + padding
        }

        guard let format, let pcmBytes, !pcmBytes.isEmpty,
            pcmBytes.count.isMultiple(of: format.blockAlign)
        else {
            throw WAVError.malformed
        }
        let frameCount = pcmBytes.count / format.blockAlign
        let duration = Double(frameCount) / Double(format.sampleRate)
        guard duration <= maximumDurationSeconds else { throw WAVError.tooLong }
        return PCM16Wave(
            sampleRate: format.sampleRate,
            channelCount: format.channels,
            frameCount: frameCount,
            pcmBytes: pcmBytes
        )
    }
}

private struct WaveFormat {
    let sampleRate: Int
    let channels: Int
    let blockAlign: Int
}

private extension Data {
    func ascii(at offset: Int, count: Int) -> String? {
        guard offset >= 0, count >= 0, offset <= self.count - count else { return nil }
        return String(data: self[offset..<(offset + count)], encoding: .ascii)
    }

    func uint16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= count - 2 else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= count - 4 else { return nil }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
