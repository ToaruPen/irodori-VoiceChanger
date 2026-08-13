@preconcurrency import AVFAudio
import Accelerate
import Foundation

public enum SmartTurnFeatureError: Error, Equatable, Sendable {
    case invalidSampleRate
    case conversionFailed
    case dftUnavailable
}

public enum SmartTurnFeatureExtractor {
    public static let sampleRate = 16_000.0
    public static let sampleCount = 128_000
    public static let melCount = 80
    public static let frameCount = 800

    private static let fftLength = 400
    private static let hopLength = 160
    private static let frequencyBinCount = fftLength / 2 + 1
    private static let melFloor = 1e-10
    private static let varianceEpsilon: Float = 1e-7

    public static func features(
        from samples: [Float],
        sampleRate sourceSampleRate: Double
    ) throws -> [Float] {
        guard sourceSampleRate.isFinite, sourceSampleRate > 0 else {
            throw SmartTurnFeatureError.invalidSampleRate
        }
        let resampled = try resample(samples, from: sourceSampleRate)
        var waveform = leftPaddedTail(resampled)
        normalize(&waveform)
        return try logMelFeatures(waveform)
    }

    private static func resample(_ samples: [Float], from sourceSampleRate: Double) throws
        -> [Float]
    {
        guard sourceSampleRate != sampleRate else { return samples }
        guard !samples.isEmpty else { return [] }
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceSampleRate,
                channels: 1,
                interleaved: false
            ),
            let destinationFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ),
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            ),
            let sourceData = sourceBuffer.floatChannelData?[0],
            let converter = AVAudioConverter(from: sourceFormat, to: destinationFormat)
        else {
            throw SmartTurnFeatureError.conversionFailed
        }
        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        sourceData.update(from: samples, count: samples.count)
        let capacity =
            AVAudioFrameCount(
                ceil(Double(samples.count) * sampleRate / sourceSampleRate)) + 64
        guard
            let destination = AVAudioPCMBuffer(
                pcmFormat: destinationFormat,
                frameCapacity: capacity
            )
        else {
            throw SmartTurnFeatureError.conversionFailed
        }
        let provider = ConversionInputProvider(buffer: sourceBuffer)
        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, inputStatus in
            provider.next(status: inputStatus)
        }
        let status = converter.convert(
            to: destination,
            error: &conversionError,
            withInputFrom: inputBlock
        )
        guard conversionError == nil,
            status == .haveData || status == .inputRanDry || status == .endOfStream,
            let output = destination.floatChannelData?[0]
        else {
            throw SmartTurnFeatureError.conversionFailed
        }
        return Array(UnsafeBufferPointer(start: output, count: Int(destination.frameLength)))
    }

    private static func leftPaddedTail(_ samples: [Float]) -> [Float] {
        let retained = samples.suffix(sampleCount)
        var result = [Float](repeating: 0, count: sampleCount)
        result.replaceSubrange((sampleCount - retained.count)..<sampleCount, with: retained)
        return result
    }

    private static func normalize(_ waveform: inout [Float]) {
        var mean: Float = 0
        vDSP_meanv(waveform, 1, &mean, vDSP_Length(waveform.count))
        var negativeMean = -mean
        waveform.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            vDSP_vsadd(
                baseAddress,
                1,
                &negativeMean,
                baseAddress,
                1,
                vDSP_Length(buffer.count)
            )
        }
        var variance: Float = 0
        vDSP_measqv(waveform, 1, &variance, vDSP_Length(waveform.count))
        var scale = 1 / sqrt(variance + varianceEpsilon)
        waveform.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            vDSP_vsmul(
                baseAddress,
                1,
                &scale,
                baseAddress,
                1,
                vDSP_Length(buffer.count)
            )
        }
    }

    private static func logMelFeatures(_ waveform: [Float]) throws -> [Float] {
        let padding = fftLength / 2
        var padded = [Float](repeating: 0, count: waveform.count + 2 * padding)
        for index in 0..<padding {
            padded[index] = waveform[padding - index]
            padded[padding + waveform.count + index] = waveform[waveform.count - 2 - index]
        }
        padded.replaceSubrange(padding..<(padding + waveform.count), with: waveform)

        let dft = try BluesteinDFT400()
        let hann = (0..<fftLength).map { index in
            Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(fftLength)))
        }
        let analysisFrameCount = frameCount + 1
        var power = [Float](
            repeating: 0,
            count: frequencyBinCount * analysisFrameCount
        )
        var realInput = [Float](repeating: 0, count: fftLength)
        for frame in 0..<analysisFrameCount {
            let start = frame * hopLength
            for index in 0..<fftLength {
                realInput[index] = padded[start + index] * hann[index]
            }
            let spectrum = dft.transform(realInput)
            for bin in 0..<frequencyBinCount {
                power[bin * analysisFrameCount + frame] =
                    spectrum.real[bin] * spectrum.real[bin]
                    + spectrum.imaginary[bin] * spectrum.imaginary[bin]
            }
        }

        let filters = melFilterbank()
        var logMel = [Float](repeating: 0, count: melCount * frameCount)
        var maximum = -Float.infinity
        for mel in 0..<melCount {
            for frame in 0..<frameCount {
                var value: Float = 0
                for bin in 0..<frequencyBinCount {
                    value +=
                        filters[bin * melCount + mel]
                        * power[bin * analysisFrameCount + frame]
                }
                let logged = log10(max(Float(melFloor), value))
                logMel[mel * frameCount + frame] = logged
                maximum = max(maximum, logged)
            }
        }
        let floor = maximum - 8
        for index in logMel.indices {
            logMel[index] = (max(logMel[index], floor) + 4) / 4
        }
        return logMel
    }

    private static func melFilterbank() -> [Float] {
        let melMinimum = hertzToMel(0)
        let melMaximum = hertzToMel(sampleRate / 2)
        let melFrequencies = (0..<(melCount + 2)).map { index in
            melMinimum
                + (melMaximum - melMinimum) * Double(index) / Double(melCount + 1)
        }
        let filterFrequencies = melFrequencies.map(melToHertz)
        var filters = [Float](repeating: 0, count: frequencyBinCount * melCount)
        for bin in 0..<frequencyBinCount {
            let frequency = sampleRate / 2 * Double(bin) / Double(frequencyBinCount - 1)
            for mel in 0..<melCount {
                let lower = filterFrequencies[mel]
                let center = filterFrequencies[mel + 1]
                let upper = filterFrequencies[mel + 2]
                let rising = (frequency - lower) / (center - lower)
                let falling = (upper - frequency) / (upper - center)
                let triangle = max(0, min(rising, falling))
                let areaNormalization = 2 / (upper - lower)
                filters[bin * melCount + mel] = Float(triangle * areaNormalization)
            }
        }
        return filters
    }

    private static func hertzToMel(_ frequency: Double) -> Double {
        guard frequency >= 1_000 else { return 3 * frequency / 200 }
        return 15 + log(frequency / 1_000) * (27 / log(6.4))
    }

    private static func melToHertz(_ mel: Double) -> Double {
        guard mel >= 15 else { return 200 * mel / 3 }
        return 1_000 * exp(log(6.4) / 27 * (mel - 15))
    }
}

private final class ConversionInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            guard !supplied else {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
}

private final class BluesteinDFT400 {
    private static let inputCount = 400
    private static let convolutionCount = 1_024

    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    private let chirpReal: [Float]
    private let chirpImaginary: [Float]
    private var kernelReal: [Float]
    private var kernelImaginary: [Float]
    private var inputReal = [Float](repeating: 0, count: convolutionCount)
    private var inputImaginary = [Float](repeating: 0, count: convolutionCount)
    private var transformedReal = [Float](repeating: 0, count: convolutionCount)
    private var transformedImaginary = [Float](repeating: 0, count: convolutionCount)
    private var productReal = [Float](repeating: 0, count: convolutionCount)
    private var productImaginary = [Float](repeating: 0, count: convolutionCount)
    private var convolutionReal = [Float](repeating: 0, count: convolutionCount)
    private var convolutionImaginary = [Float](repeating: 0, count: convolutionCount)

    init() throws {
        guard
            let forward = vDSP_DFT_zop_CreateSetup(
                nil,
                vDSP_Length(Self.convolutionCount),
                .FORWARD
            ),
            let inverse = vDSP_DFT_zop_CreateSetup(
                forward,
                vDSP_Length(Self.convolutionCount),
                .INVERSE
            )
        else {
            throw SmartTurnFeatureError.dftUnavailable
        }
        self.forward = forward
        self.inverse = inverse
        var chirpReal = [Float](repeating: 0, count: Self.inputCount)
        var chirpImaginary = [Float](repeating: 0, count: Self.inputCount)
        var kernelReal = [Float](repeating: 0, count: Self.convolutionCount)
        var kernelImaginary = [Float](repeating: 0, count: Self.convolutionCount)
        for index in 0..<Self.inputCount {
            let phase = Double.pi * Double(index * index) / Double(Self.inputCount)
            chirpReal[index] = Float(cos(phase))
            chirpImaginary[index] = Float(-sin(phase))
            let kernelImaginaryValue = Float(sin(phase))
            kernelReal[index] = Float(cos(phase))
            kernelImaginary[index] = kernelImaginaryValue
            if index > 0 {
                kernelReal[Self.convolutionCount - index] = Float(cos(phase))
                kernelImaginary[Self.convolutionCount - index] = kernelImaginaryValue
            }
        }
        var transformedKernelReal = [Float](repeating: 0, count: Self.convolutionCount)
        var transformedKernelImaginary = [Float](repeating: 0, count: Self.convolutionCount)
        vDSP_DFT_Execute(
            forward,
            &kernelReal,
            &kernelImaginary,
            &transformedKernelReal,
            &transformedKernelImaginary
        )
        self.chirpReal = chirpReal
        self.chirpImaginary = chirpImaginary
        self.kernelReal = transformedKernelReal
        self.kernelImaginary = transformedKernelImaginary
    }

    deinit {
        vDSP_DFT_DestroySetup(inverse)
        vDSP_DFT_DestroySetup(forward)
    }

    func transform(_ realSamples: [Float]) -> (real: [Float], imaginary: [Float]) {
        for index in 0..<Self.inputCount {
            inputReal[index] = realSamples[index] * chirpReal[index]
            inputImaginary[index] = realSamples[index] * chirpImaginary[index]
        }
        vDSP_DFT_Execute(
            forward,
            &inputReal,
            &inputImaginary,
            &transformedReal,
            &transformedImaginary
        )
        for index in 0..<Self.convolutionCount {
            productReal[index] =
                transformedReal[index] * kernelReal[index]
                - transformedImaginary[index] * kernelImaginary[index]
            productImaginary[index] =
                transformedReal[index] * kernelImaginary[index]
                + transformedImaginary[index] * kernelReal[index]
        }
        vDSP_DFT_Execute(
            inverse,
            &productReal,
            &productImaginary,
            &convolutionReal,
            &convolutionImaginary
        )
        let scale = Float(1) / Float(Self.convolutionCount)
        var outputReal = [Float](repeating: 0, count: Self.inputCount)
        var outputImaginary = [Float](repeating: 0, count: Self.inputCount)
        for index in 0..<Self.inputCount {
            let real = convolutionReal[index] * scale
            let imaginary = convolutionImaginary[index] * scale
            outputReal[index] = real * chirpReal[index] - imaginary * chirpImaginary[index]
            outputImaginary[index] = real * chirpImaginary[index] + imaginary * chirpReal[index]
        }
        return (outputReal, outputImaginary)
    }
}
