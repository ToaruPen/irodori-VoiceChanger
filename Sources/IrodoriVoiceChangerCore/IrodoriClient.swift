import Foundation

public struct IrodoriHealth: Codable, Equatable, Sendable {
    public let status: String
    public let modelLoaded: Bool
    public let maximumChunkSize: Int

    private enum CodingKeys: String, CodingKey {
        case status
        case modelLoaded = "model_loaded"
        case maximumChunkSize = "max_chunk_size"
    }
}

public enum IrodoriReadiness: String, Codable, Equatable, Sendable {
    case ready
    case modelLoading = "model_loading"
    case modelNotLoaded = "model_not_loaded"
    case voiceBankInvalid = "voice_bank_invalid"
}

public struct IrodoriVoice: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let aliases: [String]
    public let `default`: Bool

    public init(id: String, label: String, aliases: [String], default: Bool) {
        self.id = id
        self.label = label
        self.aliases = aliases
        self.default = `default`
    }
}

public struct ActiveVoice: Equatable, Sendable {
    public let id: String
    public let generation: String

    public init(id: String, generation: String) {
        self.id = id
        self.generation = generation
    }
}

public struct IrodoriCapabilities: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let generation: String
    public let ready: Bool
    public let readiness: IrodoriReadiness
    public let voices: [IrodoriVoice]

    public init(
        contractVersion: Int,
        generation: String,
        ready: Bool,
        readiness: IrodoriReadiness,
        voices: [IrodoriVoice]
    ) {
        self.contractVersion = contractVersion
        self.generation = generation
        self.ready = ready
        self.readiness = readiness
        self.voices = voices
    }

    public func resolveVoice(configured: String?) throws -> ActiveVoice {
        guard contractVersion == 1, ready, readiness == .ready,
            !generation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw IrodoriClientError.notReady
        }
        try validateCatalog()

        let matches: [IrodoriVoice]
        if let configured {
            matches = voices.filter { $0.id == configured || $0.aliases.contains(configured) }
        } else {
            matches = voices.filter(\.default)
        }
        guard matches.count == 1, let voice = matches.first else {
            throw IrodoriClientError.voiceNotFound
        }
        return ActiveVoice(id: voice.id, generation: generation)
    }

    fileprivate func validateCatalog() throws {
        guard !voices.isEmpty, voices.filter(\.default).count <= 1 else {
            throw IrodoriClientError.invalidResponse
        }
        var identifiers = Set<String>()
        for voice in voices {
            let id = voice.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = voice.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id == voice.id, !label.isEmpty else {
                throw IrodoriClientError.invalidResponse
            }
            for identifier in [voice.id] + voice.aliases {
                let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed == identifier,
                    identifiers.insert(identifier).inserted
                else {
                    throw IrodoriClientError.invalidResponse
                }
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case generation
        case ready
        case readiness
        case voices
    }
}

public struct SynthesisProfile: Equatable, Sendable {
    public let numSteps: Int
    public let schedule: SamplingSchedule
    public let style: IrodoriStyle
    public let swayCoefficient: Double

    public init(
        numSteps: Int,
        schedule: SamplingSchedule,
        style: IrodoriStyle,
        swayCoefficient: Double
    ) {
        self.numSteps = numSteps
        self.schedule = schedule
        self.style = style
        self.swayCoefficient = swayCoefficient
    }
}

public struct SynthesizedAudio: Equatable, Sendable {
    public let wavBytes: Data
    public let serverElapsedSeconds: Double
}

public enum SynthesisMilestone: Equatable, Sendable {
    case handshake
    case firstAudioPayload
    case completed(serverElapsedMilliseconds: Double?, samplingSteps: Int?)
}

public enum IrodoriClientError: Error, Equatable, Sendable {
    case remoteUnavailable
    case notReady
    case voiceNotFound
    case invalidResponse
    case responseTooLarge
    case remote(IrodoriRemoteError)
}

public extension IrodoriClientError {
    var stableCode: StableErrorCode {
        switch self {
        case .remoteUnavailable: .remoteUnavailable
        case .notReady, .invalidResponse: .invalidResponse
        case .voiceNotFound: .voiceNotFound
        case .responseTooLarge: .responseTooLarge
        case .remote(.backpressure): .backpressure
        case .remote(.backendUnavailable): .remoteUnavailable
        case .remote(.runtimeGenerationMismatch): .runtimeGenerationMismatch
        case .remote(.voiceNotFound): .voiceNotFound
        }
    }
}

public actor IrodoriClient {
    private static let maximumMetadataBytes = 1_048_576
    private static let maximumStreamFrames = 16_384

    private let baseURL: URL
    private let session: URLSession
    private var advertisedMaximumChunkSize: Int?

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func health() async throws -> IrodoriHealth {
        let health: IrodoriHealth = try await requestJSON(path: "health", schema: .health)
        guard health.status == "ok", health.modelLoaded, health.maximumChunkSize > 0 else {
            throw IrodoriClientError.notReady
        }
        advertisedMaximumChunkSize = health.maximumChunkSize
        return health
    }

    public func capabilities() async throws -> IrodoriCapabilities {
        let capabilities: IrodoriCapabilities = try await requestJSON(
            path: "capabilities", schema: .capabilities)
        if capabilities.ready, capabilities.readiness == .ready {
            try capabilities.validateCatalog()
        }
        return capabilities
    }

    public func prepareVoice(configuredVoiceID: String?) async throws -> ActiveVoice {
        try await capabilities().resolveVoice(configured: configuredVoiceID)
    }

    public func synthesize(
        text: String,
        voice: ActiveVoice,
        profile: SynthesisProfile,
        maximumBytes: Int,
        onMilestone: @Sendable (SynthesisMilestone) async -> Void
    ) async throws -> SynthesizedAudio {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IrodoriClientError.invalidResponse
        }
        let payload = SynthesisRequest(
            text: text,
            voiceID: voice.id,
            expectedGeneration: voice.generation,
            numSteps: profile.numSteps,
            style: profile.style,
            schedule: profile.schedule,
            swayCoefficient: profile.swayCoefficient
        )
        var request = URLRequest(url: endpoint("synthesize_stream"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.httpBody = try JSONEncoder().encode(payload)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw IrodoriClientError.remoteUnavailable
        }
        guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            isIdentityEncoded(httpResponse),
            httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased()
                .hasPrefix("application/octet-stream") == true
        else {
            throw IrodoriClientError.remoteUnavailable
        }

        var parser = IrodoriStreamParser(
            maximumTotalBytes: maximumBytes,
            maximumFrames: Self.maximumStreamFrames,
            advertisedMaximumChunkSize: advertisedMaximumChunkSize
        )
        var wavBytes = Data()
        var serverElapsed = 0.0
        var inputBuffer = Data()
        inputBuffer.reserveCapacity(8_192)

        do {
            for try await byte in bytes {
                inputBuffer.append(byte)
                if byte == 0x0A || parser.waitingForFirstPayloadByte
                    || inputBuffer.count >= 8_192
                {
                    try await consume(
                        inputBuffer,
                        parser: &parser,
                        wavBytes: &wavBytes,
                        serverElapsed: &serverElapsed,
                        onMilestone: onMilestone
                    )
                    inputBuffer.removeAll(keepingCapacity: true)
                }
            }
            if !inputBuffer.isEmpty {
                try await consume(
                    inputBuffer,
                    parser: &parser,
                    wavBytes: &wavBytes,
                    serverElapsed: &serverElapsed,
                    onMilestone: onMilestone
                )
            }
            try parser.finish()
        } catch IrodoriWireError.remote(let remoteError) {
            throw IrodoriClientError.remote(remoteError)
        } catch is IrodoriWireError {
            throw IrodoriClientError.invalidResponse
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw IrodoriClientError.remoteUnavailable
        }

        await onMilestone(
            .completed(
                serverElapsedMilliseconds: serverElapsed * 1_000,
                samplingSteps: profile.numSteps
            ))
        return SynthesizedAudio(wavBytes: wavBytes, serverElapsedSeconds: serverElapsed)
    }

    private func consume(
        _ data: Data,
        parser: inout IrodoriStreamParser,
        wavBytes: inout Data,
        serverElapsed: inout Double,
        onMilestone: @Sendable (SynthesisMilestone) async -> Void
    ) async throws {
        for event in try parser.feed(data) {
            switch event {
            case .handshake:
                await onMilestone(.handshake)
            case .audioPayloadStarted:
                await onMilestone(.firstAudioPayload)
            case .audio(let payload, _, let elapsedSeconds):
                serverElapsed = elapsedSeconds
                if !payload.isEmpty {
                    wavBytes.append(payload)
                }
            }
        }
    }

    private func requestJSON<Value: Decodable>(
        path: String,
        schema: IrodoriMetadataSchema
    ) async throws -> Value {
        do {
            let (data, response) = try await session.data(from: endpoint(path))
            guard let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode)
            else {
                throw IrodoriClientError.remoteUnavailable
            }
            guard data.count <= Self.maximumMetadataBytes else {
                throw IrodoriClientError.responseTooLarge
            }
            do {
                try schema.validate(data)
                return try JSONDecoder().decode(Value.self, from: data)
            } catch {
                throw IrodoriClientError.invalidResponse
            }
        } catch let error as IrodoriClientError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw IrodoriClientError.remoteUnavailable
        }
    }

    private func endpoint(_ path: String) -> URL {
        baseURL.appending(path: path)
    }

    private func isIdentityEncoded(_ response: HTTPURLResponse) -> Bool {
        guard let encoding = response.value(forHTTPHeaderField: "Content-Encoding") else {
            return true
        }
        return encoding.caseInsensitiveCompare("identity") == .orderedSame
    }
}

private enum IrodoriMetadataSchema {
    case health
    case capabilities

    func validate(_ data: Data) throws {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw IrodoriClientError.invalidResponse
        }
        let allowed: Set<String>
        switch self {
        case .health:
            allowed = ["status", "model_loaded", "max_chunk_size", "detail"]
        case .capabilities:
            allowed = [
                "contract_version", "generation", "ready", "readiness", "conditioning", "voices",
            ]
            guard let voices = object["voices"] as? [[String: Any]] else {
                throw IrodoriClientError.invalidResponse
            }
            let voiceKeys: Set<String> = ["id", "label", "aliases", "default"]
            guard voices.allSatisfy({ Set($0.keys).isSubset(of: voiceKeys) }) else {
                throw IrodoriClientError.invalidResponse
            }
        }
        guard Set(object.keys).isSubset(of: allowed) else {
            throw IrodoriClientError.invalidResponse
        }
    }
}

public actor ConfiguredIrodoriSynthesizer: Synthesizing {
    private let client: IrodoriClient
    private let voice: ActiveVoice
    private let profile: SynthesisProfile
    private let maximumBytes: Int
    private let maximumDurationSeconds: Double

    public init(
        client: IrodoriClient,
        voice: ActiveVoice,
        profile: SynthesisProfile,
        maximumBytes: Int,
        maximumDurationSeconds: Double
    ) {
        self.client = client
        self.voice = voice
        self.profile = profile
        self.maximumBytes = maximumBytes
        self.maximumDurationSeconds = maximumDurationSeconds
    }

    public func synthesize(
        text: String,
        utteranceID _: UUID,
        onMilestone: @Sendable (SynthesisMilestone) async -> Void
    ) async throws -> AudioClip {
        let result = try await client.synthesize(
            text: text,
            voice: voice,
            profile: profile,
            maximumBytes: maximumBytes,
            onMilestone: onMilestone
        )
        let wave: PCM16Wave
        do {
            wave = try PCM16Wave.decode(
                result.wavBytes,
                maximumBytes: maximumBytes,
                maximumDurationSeconds: maximumDurationSeconds
            )
        } catch {
            throw PipelineOperationError(.invalidWAV)
        }
        return AudioClip(
            wavBytes: result.wavBytes,
            durationMilliseconds: wave.durationMilliseconds
        )
    }
}

private struct SynthesisRequest: Encodable {
    let text: String
    let voiceID: String
    let expectedGeneration: String
    let numSteps: Int
    let style: IrodoriStyle
    let schedule: SamplingSchedule
    let swayCoefficient: Double

    private enum CodingKeys: String, CodingKey {
        case text
        case voiceID = "voice_id"
        case expectedGeneration = "if_generation"
        case numSteps = "num_steps"
        case style
        case schedule = "t_schedule_mode"
        case swayCoefficient = "sway_coeff"
    }
}
