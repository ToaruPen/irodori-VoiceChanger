import Foundation
import Testing

@testable import IrodoriVoiceChangerCore

@Suite("IrodoriWireTests")
struct IrodoriWireTests {
    @Test
    func validStreamParsesAcrossEveryByteBoundary() throws {
        let stream = framedStream(payloads: [Data("RIFF".utf8), Data("WAVE".utf8)])

        for split in 0...stream.count {
            var parser = IrodoriStreamParser(maximumTotalBytes: 64, maximumFrames: 4)
            let first = try parser.feed(Data(stream.prefix(split)))
            let second = try parser.feed(Data(stream.dropFirst(split)))
            try parser.finish()
            let events = first + second
            #expect(events.first == .handshake(maximumChunkSize: 16))
            #expect(events.compactMap(\.payload) == [Data("RIFF".utf8), Data("WAVE".utf8)])
            #expect(events.last?.isFinal == true)
        }
    }

    @Test
    func malformedStreamsFailClosed() throws {
        let valid = framedStream(payloads: [Data("x".utf8)])
        let noHandshake = line(
            #"{"kind":"chunk","v":1,"index":0,"nbytes":0,"final":true,"elapsed":0.1}"#)
        let duplicateHandshake = line(#"{"kind":"handshake","v":1,"max_chunk_size":16}"#) + valid
        let missingFinal = framedStream(payloads: [Data("x".utf8)], final: false)

        #expect(throws: IrodoriWireError.self) {
            var parser = IrodoriStreamParser(maximumTotalBytes: 64, maximumFrames: 4)
            _ = try parser.feed(noHandshake)
        }
        #expect(throws: IrodoriWireError.self) {
            var parser = IrodoriStreamParser(maximumTotalBytes: 64, maximumFrames: 4)
            _ = try parser.feed(Data(duplicateHandshake))
        }
        #expect(throws: IrodoriWireError.self) {
            var parser = IrodoriStreamParser(maximumTotalBytes: 64, maximumFrames: 4)
            _ = try parser.feed(missingFinal)
            try parser.finish()
        }
    }

    @Test
    func payloadAndFrameBoundsAreEnforced() throws {
        let twoFrames = framedStream(payloads: [Data("a".utf8), Data("b".utf8)])

        #expect(throws: IrodoriWireError.self) {
            var parser = IrodoriStreamParser(maximumTotalBytes: 1, maximumFrames: 4)
            _ = try parser.feed(twoFrames)
        }
        #expect(throws: IrodoriWireError.self) {
            var parser = IrodoriStreamParser(maximumTotalBytes: 64, maximumFrames: 1)
            _ = try parser.feed(twoFrames)
        }
    }

    @Test
    func terminalRemoteErrorIsTyped() throws {
        let bytes =
            line(#"{"kind":"handshake","v":1,"max_chunk_size":16}"#)
            + line(
                #"{"kind":"chunk","v":1,"index":0,"nbytes":0,"final":true,"elapsed":0.0,"error_code":"backpressure"}"#
            )

        #expect(throws: IrodoriWireError.remote(.backpressure)) {
            var parser = IrodoriStreamParser(maximumTotalBytes: 64, maximumFrames: 4)
            _ = try parser.feed(bytes)
        }
    }

    @Test
    func exposesHeaderAndFirstPayloadByteBeforeTheCompleteFrame() throws {
        var parser = IrodoriStreamParser(maximumTotalBytes: 64, maximumFrames: 4)
        let handshake = line(#"{"kind":"handshake","v":1,"max_chunk_size":16}"#)
        let chunk = line(
            #"{"kind":"chunk","v":1,"index":0,"nbytes":4,"final":true,"elapsed":0.1}"#)

        #expect(try parser.feed(handshake) == [.handshake(maximumChunkSize: 16)])
        #expect(try parser.feed(chunk).isEmpty)
        #expect(parser.waitingForFirstPayloadByte)
        #expect(try parser.feed(Data("R".utf8)) == [.audioPayloadStarted])
        #expect(try parser.feed(Data("IFF".utf8)).last?.isFinal == true)
    }

    private func framedStream(payloads: [Data], final: Bool = true) -> Data {
        var data = line(#"{"kind":"handshake","v":1,"max_chunk_size":16}"#)
        for (index, payload) in payloads.enumerated() {
            let isFinal = final && index == payloads.count - 1
            data.append(
                line(
                    #"{"kind":"chunk","v":1,"index":\#(index),"nbytes":\#(payload.count),"final":\#(isFinal),"elapsed":0.25}"#
                ))
            data.append(payload)
        }
        return data
    }

    private func line(_ value: String) -> Data {
        Data((value + "\n").utf8)
    }
}

private extension IrodoriStreamEvent {
    var payload: Data? {
        if case .audioPayloadStarted = self { return nil }
        guard case .audio(let payload, _, _) = self else { return nil }
        return payload
    }

    var isFinal: Bool {
        if case .audioPayloadStarted = self { return false }
        guard case .audio(_, let final, _) = self else { return false }
        return final
    }
}
