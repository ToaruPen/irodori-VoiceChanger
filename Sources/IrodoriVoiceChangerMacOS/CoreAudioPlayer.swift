import AVFAudio
import AudioToolbox
import Foundation
import IrodoriVoiceChangerCore

@MainActor
public final class CoreAudioPlayer: AudioPlaying {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let maximumWAVBytes: Int
    private let maximumClipSeconds: Double
    private var connectedFormat: AVAudioFormat?

    public init(
        device: AudioOutputDevice,
        maximumWAVBytes: Int,
        maximumClipSeconds: Double
    ) throws {
        self.maximumWAVBytes = maximumWAVBytes
        self.maximumClipSeconds = maximumClipSeconds
        engine.attach(player)
        guard let audioUnit = engine.outputNode.audioUnit else {
            throw PipelineOperationError(.outputUnavailable)
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw PipelineOperationError(.outputUnavailable)
        }
    }

    public func play(_ audio: AudioClip, utteranceID _: UUID) async throws {
        let wave: PCM16Wave
        do {
            wave = try PCM16Wave.decode(
                audio.wavBytes,
                maximumBytes: maximumWAVBytes,
                maximumDurationSeconds: maximumClipSeconds
            )
        } catch {
            throw PipelineOperationError(.invalidWAV)
        }
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(wave.sampleRate),
                channels: AVAudioChannelCount(wave.channelCount),
                interleaved: true
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(wave.frameCount)
            )
        else {
            throw PipelineOperationError(.invalidWAV)
        }
        buffer.frameLength = AVAudioFrameCount(wave.frameCount)
        guard let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
            throw PipelineOperationError(.invalidWAV)
        }
        wave.pcmBytes.copyBytes(
            to: destination.assumingMemoryBound(to: UInt8.self), count: wave.pcmBytes.count)
        buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(wave.pcmBytes.count)

        try connectIfNeeded(format: format)
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                throw PipelineOperationError(.outputUnavailable)
            }
        }

        await withCheckedContinuation { continuation in
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                continuation.resume()
            }
            player.play()
        }
    }

    public func stop() {
        player.stop()
        engine.stop()
    }

    private func connectIfNeeded(format: AVAudioFormat) throws {
        if let connectedFormat,
            connectedFormat.sampleRate == format.sampleRate,
            connectedFormat.channelCount == format.channelCount
        {
            return
        }
        if engine.isRunning {
            engine.stop()
        }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        connectedFormat = format
    }
}
