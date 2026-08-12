import AudioToolbox
import Testing

@testable import IrodoriVoiceChangerMacOS

@Suite("CoreAudioDeviceTests")
struct CoreAudioDeviceTests {
    @Test
    func resolvesOneOutputByExactUID() throws {
        let catalog = AudioDeviceCatalog(devices: [
            .init(id: 10, uid: "built-in", name: "Built-in", outputChannelCount: 2),
            .init(id: 20, uid: "virtual", name: "Virtual", outputChannelCount: 2),
        ])

        #expect(try catalog.resolveOutput(uid: "virtual").id == 20)
    }

    @Test
    func missingDuplicateAndInputOnlyDevicesFailWithoutFallback() {
        let inputOnly = AudioDeviceCatalog(devices: [
            .init(id: 10, uid: "input", name: "Input", outputChannelCount: 0)
        ])
        let duplicate = AudioDeviceCatalog(devices: [
            .init(id: 10, uid: "same", name: "A", outputChannelCount: 2),
            .init(id: 20, uid: "same", name: "B", outputChannelCount: 2),
        ])

        #expect(throws: AudioDeviceError.outputUnavailable) {
            _ = try inputOnly.resolveOutput(uid: "input")
        }
        #expect(throws: AudioDeviceError.outputUnavailable) {
            _ = try inputOnly.resolveOutput(uid: "missing")
        }
        #expect(throws: AudioDeviceError.ambiguousUID) {
            _ = try duplicate.resolveOutput(uid: "same")
        }
    }
}
