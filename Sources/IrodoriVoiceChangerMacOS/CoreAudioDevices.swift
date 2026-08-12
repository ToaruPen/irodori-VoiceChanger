import AudioToolbox
import CoreAudio
import Foundation

public struct AudioOutputDevice: Equatable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let outputChannelCount: Int

    public init(id: AudioDeviceID, uid: String, name: String, outputChannelCount: Int) {
        self.id = id
        self.uid = uid
        self.name = name
        self.outputChannelCount = outputChannelCount
    }
}

public enum AudioDeviceError: Error, Equatable, Sendable {
    case queryFailed(OSStatus)
    case outputUnavailable
    case ambiguousUID
}

public struct AudioDeviceCatalog: Sendable {
    public let devices: [AudioOutputDevice]

    public init(devices: [AudioOutputDevice]) {
        self.devices = devices
    }

    public static func current() throws -> AudioDeviceCatalog {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount))
        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return AudioDeviceCatalog(devices: []) }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        try ids.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw AudioDeviceError.outputUnavailable
            }
            try check(
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &byteCount,
                    baseAddress
                ))
        }
        let outputs = try ids.map { id in
            AudioOutputDevice(
                id: id,
                uid: try stringProperty(id: id, selector: kAudioDevicePropertyDeviceUID),
                name: try stringProperty(id: id, selector: kAudioObjectPropertyName),
                outputChannelCount: try outputChannelCount(id: id)
            )
        }
        return AudioDeviceCatalog(devices: outputs)
    }

    public func resolveOutput(uid: String) throws -> AudioOutputDevice {
        let matches = devices.filter { $0.uid == uid }
        guard matches.count <= 1 else { throw AudioDeviceError.ambiguousUID }
        guard let device = matches.first, device.outputChannelCount > 0 else {
            throw AudioDeviceError.outputUnavailable
        }
        return device
    }

    public var outputs: [AudioOutputDevice] {
        devices.filter { $0.outputChannelCount > 0 }
    }
}

private func stringProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector) throws
    -> String
{
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var unmanagedValue: Unmanaged<CFString>?
    var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(id, &address, 0, nil, &byteCount, &unmanagedValue))
    guard let value = unmanagedValue?.takeUnretainedValue() else {
        throw AudioDeviceError.outputUnavailable
    }
    return value as String
}

private func outputChannelCount(id: AudioDeviceID) throws -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var byteCount: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &byteCount))
    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: Int(byteCount),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { storage.deallocate() }
    try check(AudioObjectGetPropertyData(id, &address, 0, nil, &byteCount, storage))
    let list = storage.assumingMemoryBound(to: AudioBufferList.self)
    return UnsafeMutableAudioBufferListPointer(list).reduce(0) {
        $0 + Int($1.mNumberChannels)
    }
}

private func check(_ status: OSStatus) throws {
    guard status == noErr else { throw AudioDeviceError.queryFailed(status) }
}
