import AVFAudio
import Foundation
import Speech
import os

public struct MicrophoneInput: Sendable {
    public let stream: AsyncStream<AnalyzerInput>
    private let dropCounter: InputDropCounter

    fileprivate init(stream: AsyncStream<AnalyzerInput>, dropCounter: InputDropCounter) {
        self.stream = stream
        self.dropCounter = dropCounter
    }

    public var droppedBufferCount: Int {
        dropCounter.value
    }
}

@MainActor
public final class MicrophoneCapture {
    private let engine: AVAudioEngine
    private var rawContinuation: AsyncStream<SendablePCMBuffer>.Continuation?
    private var conversionTask: Task<Void, Never>?
    private var running = false

    public init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    public func start(
        analysisFormat: AVAudioFormat,
        bufferFrames: AVAudioFrameCount
    ) throws -> MicrophoneInput {
        guard !running else { throw MicrophoneCaptureError.alreadyRunning }
        running = true

        let inputNode = engine.inputNode
        let naturalFormat = inputNode.outputFormat(forBus: 0)
        guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else {
            running = false
            throw MicrophoneCaptureError.inputUnavailable
        }
        let (rawStream, rawContinuation) = AsyncStream.makeStream(
            of: SendablePCMBuffer.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        let (stream, continuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        let dropCounter = InputDropCounter()
        self.rawContinuation = rawContinuation
        let converter = AVAudioConverter(from: naturalFormat, to: analysisFormat)
        conversionTask = Task.detached {
            for await item in rawStream {
                guard !Task.isCancelled else { break }
                let buffer = item.value
                if naturalFormat == analysisFormat {
                    if case .dropped = continuation.yield(AnalyzerInput(buffer: buffer)) {
                        dropCounter.increment()
                    }
                } else if let converter,
                    let converted = buffer.converted(using: converter, to: analysisFormat)
                {
                    if case .dropped = continuation.yield(AnalyzerInput(buffer: converted)) {
                        dropCounter.increment()
                    }
                }
            }
            continuation.finish()
        }
        let tapHandler = makeMicrophoneTapHandler { buffer in
            guard let copy = buffer.copyForAsyncUse() else {
                dropCounter.increment()
                return
            }
            if case .dropped = rawContinuation.yield(SendablePCMBuffer(copy)) {
                dropCounter.increment()
            }
        }
        inputNode.installTap(
            onBus: 0,
            bufferSize: bufferFrames,
            format: naturalFormat,
            block: tapHandler
        )
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            rawContinuation.finish()
            self.rawContinuation = nil
            conversionTask?.cancel()
            conversionTask = nil
            running = false
            throw error
        }
        return MicrophoneInput(stream: stream, dropCounter: dropCounter)
    }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        let rawContinuation = rawContinuation
        self.rawContinuation = nil
        rawContinuation?.finish()
        conversionTask?.cancel()
        conversionTask = nil
    }
}

func makeMicrophoneTapHandler(
    _ body: @escaping @Sendable (AVAudioPCMBuffer) -> Void
) -> AVAudioNodeTapBlock {
    { buffer, _ in body(buffer) }
}

private final class InputDropCounter: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: 0)

    var value: Int { storage.withLock { $0 } }

    func increment() {
        storage.withLock { $0 += 1 }
    }
}

private struct SendablePCMBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer

    init(_ value: AVAudioPCMBuffer) {
        self.value = value
    }
}

public enum MicrophoneCaptureError: Error, Equatable, Sendable {
    case alreadyRunning
    case inputUnavailable
}

private extension AVAudioPCMBuffer {
    func converted(using converter: AVAudioConverter, to format: AVAudioFormat)
        -> AVAudioPCMBuffer?
    {
        let ratio = format.sampleRate / self.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        let inputProvider = ConversionInputProvider(buffer: self)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            inputProvider.next(status: inputStatus)
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
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
}

private extension AVAudioPCMBuffer {
    func copyForAsyncUse() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            let source = sourceBuffers[index]
            guard let sourceData = source.mData,
                let destinationData = destinationBuffers[index].mData
            else {
                return nil
            }
            memcpy(destinationData, sourceData, Int(source.mDataByteSize))
            destinationBuffers[index].mDataByteSize = source.mDataByteSize
        }
        return copy
    }
}
