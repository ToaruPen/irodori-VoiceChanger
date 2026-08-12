import Foundation

public enum IrodoriRemoteError: String, Codable, Equatable, Sendable {
    case backpressure
    case backendUnavailable = "backend_unavailable"
    case runtimeGenerationMismatch = "runtime_generation_mismatch"
    case voiceNotFound = "voice_not_found"
}

public enum IrodoriWireError: Error, Equatable, Sendable {
    case handshakeRequired
    case duplicateHandshake
    case invalidHeader
    case unsupportedVersion
    case invalidIndex
    case chunkTooLarge
    case payloadTooLarge
    case frameLimit
    case missingFinal
    case truncated
    case framesAfterFinal
    case remote(IrodoriRemoteError)
}

public enum IrodoriStreamEvent: Equatable, Sendable {
    case handshake(maximumChunkSize: Int)
    case audioPayloadStarted
    case audio(Data, final: Bool, elapsedSeconds: Double)
}

public struct IrodoriStreamParser: Sendable {
    private static let maximumHeaderBytes = 4_096
    private static let protocolMaximumChunkBytes = 4 * 1_024 * 1_024

    private let maximumTotalBytes: Int
    private let maximumFrames: Int
    private let advertisedMaximumChunkSize: Int?
    private var buffer = Data()
    private var maximumChunkSize: Int?
    private var pendingChunk: PendingChunk?
    private var nextIndex = 0
    private var totalBytes = 0
    private var frameCount = 0
    private var finalSeen = false
    private var firstAudioPayloadSeen = false

    var waitingForFirstPayloadByte: Bool {
        guard let pendingChunk else { return false }
        return pendingChunk.byteCount > 0 && !firstAudioPayloadSeen
    }

    public init(
        maximumTotalBytes: Int,
        maximumFrames: Int,
        advertisedMaximumChunkSize: Int? = nil
    ) {
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumFrames = maximumFrames
        self.advertisedMaximumChunkSize = advertisedMaximumChunkSize
    }

    public mutating func feed(_ bytes: Data) throws -> [IrodoriStreamEvent] {
        guard !finalSeen || bytes.isEmpty else {
            throw IrodoriWireError.framesAfterFinal
        }
        buffer.append(bytes)
        var events = [IrodoriStreamEvent]()

        while true {
            if let pendingChunk {
                if pendingChunk.byteCount > 0, !firstAudioPayloadSeen, !buffer.isEmpty {
                    firstAudioPayloadSeen = true
                    events.append(.audioPayloadStarted)
                }
                guard buffer.count >= pendingChunk.byteCount else {
                    break
                }
                let payload = Data(buffer.prefix(pendingChunk.byteCount))
                buffer.removeFirst(pendingChunk.byteCount)
                self.pendingChunk = nil
                if let remoteError = pendingChunk.remoteError {
                    finalSeen = true
                    guard buffer.isEmpty else { throw IrodoriWireError.framesAfterFinal }
                    throw IrodoriWireError.remote(remoteError)
                }
                events.append(
                    .audio(
                        payload,
                        final: pendingChunk.final,
                        elapsedSeconds: pendingChunk.elapsedSeconds
                    )
                )
                if pendingChunk.final {
                    finalSeen = true
                    guard buffer.isEmpty else { throw IrodoriWireError.framesAfterFinal }
                    break
                }
                continue
            }

            guard let newlineIndex = buffer.firstIndex(of: 0x0A) else {
                guard buffer.count <= Self.maximumHeaderBytes else {
                    throw IrodoriWireError.invalidHeader
                }
                break
            }
            let header = Data(buffer[..<newlineIndex])
            buffer.removeFirst(buffer.distance(from: buffer.startIndex, to: newlineIndex) + 1)
            guard !header.isEmpty else { throw IrodoriWireError.invalidHeader }

            if maximumChunkSize == nil {
                let maximum = try parseHandshake(header)
                maximumChunkSize = maximum
                events.append(.handshake(maximumChunkSize: maximum))
            } else {
                try parseChunk(header)
            }
        }

        return events
    }

    public func finish() throws {
        guard maximumChunkSize != nil else { throw IrodoriWireError.handshakeRequired }
        guard pendingChunk == nil, buffer.isEmpty else { throw IrodoriWireError.truncated }
        guard finalSeen else { throw IrodoriWireError.missingFinal }
    }

    private mutating func parseHandshake(_ data: Data) throws -> Int {
        let object = try dictionary(from: data)
        if object["kind"] as? String != "handshake" {
            throw IrodoriWireError.handshakeRequired
        }
        guard Set(object.keys) == ["kind", "v", "max_chunk_size"],
            integer(object["v"]) == 1,
            let maximum = integer(object["max_chunk_size"]),
            maximum > 0,
            maximum
                <= min(
                    Self.protocolMaximumChunkBytes,
                    advertisedMaximumChunkSize ?? maximumTotalBytes
                )
        else {
            if integer(object["v"]) != 1 { throw IrodoriWireError.unsupportedVersion }
            throw IrodoriWireError.invalidHeader
        }
        return maximum
    }

    private mutating func parseChunk(_ data: Data) throws {
        let object = try dictionary(from: data)
        if object["kind"] as? String == "handshake" {
            throw IrodoriWireError.duplicateHandshake
        }
        guard object["kind"] as? String == "chunk" else {
            throw IrodoriWireError.invalidHeader
        }
        let allowedKeys: Set<String> = [
            "kind", "v", "index", "nbytes", "final", "elapsed", "error_code",
        ]
        guard Set(object.keys).isSubset(of: allowedKeys), integer(object["v"]) == 1,
            let index = integer(object["index"]),
            let byteCount = integer(object["nbytes"]),
            let final = object["final"] as? Bool,
            let elapsedSeconds = number(object["elapsed"]),
            elapsedSeconds.isFinite,
            elapsedSeconds >= 0
        else {
            if integer(object["v"]) != 1 { throw IrodoriWireError.unsupportedVersion }
            throw IrodoriWireError.invalidHeader
        }
        guard index == nextIndex, index <= Int(UInt32.max) else {
            throw IrodoriWireError.invalidIndex
        }
        guard let maximumChunkSize, byteCount >= 0, byteCount <= maximumChunkSize else {
            throw IrodoriWireError.chunkTooLarge
        }
        guard frameCount < maximumFrames else { throw IrodoriWireError.frameLimit }
        guard totalBytes <= maximumTotalBytes - byteCount else {
            throw IrodoriWireError.payloadTooLarge
        }

        let remoteError: IrodoriRemoteError?
        if let rawError = object["error_code"] as? String {
            guard let decoded = IrodoriRemoteError(rawValue: rawError), final, byteCount == 0 else {
                throw IrodoriWireError.invalidHeader
            }
            remoteError = decoded
        } else {
            remoteError = nil
        }

        nextIndex += 1
        frameCount += 1
        totalBytes += byteCount
        pendingChunk = PendingChunk(
            byteCount: byteCount,
            final: final,
            elapsedSeconds: elapsedSeconds,
            remoteError: remoteError
        )
    }

    private func dictionary(from data: Data) throws -> [String: Any] {
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw IrodoriWireError.invalidHeader
            }
            return value
        } catch let error as IrodoriWireError {
            throw error
        } catch {
            throw IrodoriWireError.invalidHeader
        }
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double,
            double >= Double(Int.min), double <= Double(Int.max)
        else {
            return nil
        }
        return Int(double)
    }

    private func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        return number.doubleValue
    }
}

private struct PendingChunk: Sendable {
    let byteCount: Int
    let final: Bool
    let elapsedSeconds: Double
    let remoteError: IrodoriRemoteError?
}
