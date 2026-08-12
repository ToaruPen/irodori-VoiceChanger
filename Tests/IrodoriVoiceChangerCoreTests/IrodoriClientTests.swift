import Foundation
import Testing

@testable import IrodoriVoiceChangerCore

@Suite("IrodoriClientTests", .serialized)
struct IrodoriClientTests {
    @Test
    func resolvesDefaultAndAliasAgainstGeneration() throws {
        let capabilities = IrodoriCapabilities(
            contractVersion: 1,
            generation: "generation-1",
            ready: true,
            readiness: .ready,
            voices: [
                .init(id: "voice-a", label: "A", aliases: ["legacy-a"], default: true),
                .init(id: "voice-b", label: "B", aliases: [], default: false),
            ]
        )

        #expect(try capabilities.resolveVoice(configured: nil).id == "voice-a")
        #expect(try capabilities.resolveVoice(configured: "legacy-a").id == "voice-a")
        #expect(try capabilities.resolveVoice(configured: "voice-b").generation == "generation-1")
        #expect(throws: IrodoriClientError.voiceNotFound) {
            try capabilities.resolveVoice(configured: "missing")
        }
    }

    @Test
    func rejectsEmptyOrCollidingVoiceCatalogEntries() {
        let invalidCatalogs = [
            IrodoriCapabilities(
                contractVersion: 1,
                generation: "generation-1",
                ready: true,
                readiness: .ready,
                voices: [.init(id: "", label: "A", aliases: [], default: true)]
            ),
            IrodoriCapabilities(
                contractVersion: 1,
                generation: "generation-1",
                ready: true,
                readiness: .ready,
                voices: [
                    .init(id: "voice-a", label: "A", aliases: ["shared"], default: true),
                    .init(id: "voice-b", label: "B", aliases: ["shared"], default: false),
                ]
            ),
            IrodoriCapabilities(
                contractVersion: 1,
                generation: "generation-1",
                ready: true,
                readiness: .ready,
                voices: [
                    .init(id: "voice-a", label: "A", aliases: [], default: true),
                    .init(id: "voice-b", label: "B", aliases: ["voice-a"], default: false),
                ]
            ),
        ]

        for capabilities in invalidCatalogs {
            #expect(throws: IrodoriClientError.invalidResponse) {
                try capabilities.resolveVoice(configured: "voice-a")
            }
        }
    }

    @Test
    func metadataRejectsUnknownFields() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path == "/health" {
                return try Self.response(
                    request,
                    body:
                        #"{"status":"ok","model_loaded":true,"max_chunk_size":16,"future":true}"#
                )
            }
            return try Self.response(
                request,
                body:
                    #"{"contract_version":1,"generation":"g1","ready":true,"readiness":"ready","voices":[{"id":"v1","label":"Voice","aliases":[],"default":true,"future":true}]}"#
            )
        }
        let client = IrodoriClient(
            baseURL: try #require(URL(string: "https://unit.test")), session: stubSession())

        await #expect(throws: IrodoriClientError.invalidResponse) {
            _ = try await client.health()
        }
        await #expect(throws: IrodoriClientError.invalidResponse) {
            _ = try await client.capabilities()
        }
    }

    @Test
    func metadataAcceptsDocumentedFieldsNotConsumedByTheClient() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path == "/health" {
                return try Self.response(
                    request,
                    body:
                        #"{"status":"ok","model_loaded":true,"max_chunk_size":16,"detail":null}"#
                )
            }
            return try Self.response(
                request,
                body:
                    #"{"contract_version":1,"generation":"g1","ready":true,"readiness":"ready","conditioning":{"#
                    + #""delivery_caption":{"max_chars":1000,"supported":true},"emoji":{"supported":true}},"#
                    + #""voices":[{"id":"v1","label":"Voice","aliases":[],"default":true}]}"#
            )
        }
        let client = IrodoriClient(
            baseURL: try #require(URL(string: "https://unit.test")), session: stubSession())

        _ = try await client.health()
        _ = try await client.capabilities()
    }

    @Test
    func clientChecksReadinessAndStreamsAudio() async throws {
        URLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/health":
                return try Self.response(
                    request, body: #"{"status":"ok","model_loaded":true,"max_chunk_size":16}"#)
            case "/capabilities":
                return try Self.response(
                    request,
                    body:
                        #"{"contract_version":1,"generation":"g1","ready":true,"readiness":"ready","voices":[{"id":"v1","label":"Voice","aliases":[],"default":true}]}"#
                )
            case "/synthesize_stream":
                let requestBody = try #require(Self.body(of: request))
                let body = try #require(String(data: requestBody, encoding: .utf8))
                #expect(body.contains(#""voice_id":"v1""#))
                #expect(body.contains(#""if_generation":"g1""#))
                return try Self.response(
                    request,
                    data: Data(
                        (#"{"kind":"handshake","v":1,"max_chunk_size":16}"# + "\n"
                            + #"{"kind":"chunk","v":1,"index":0,"nbytes":8,"final":true,"elapsed":0.25}"#
                            + "\nRIFFWAVE").utf8
                    ),
                    contentType: "application/octet-stream"
                )
            default:
                return try Self.response(request, status: 404, body: "{}")
            }
        }
        let client = IrodoriClient(
            baseURL: try #require(URL(string: "https://unit.test")), session: stubSession())

        let health = try await client.health()
        #expect(health.modelLoaded)
        let activeVoice = try await client.prepareVoice(configuredVoiceID: nil)
        let milestoneCollector = MilestoneCollector()
        let audio = try await client.synthesize(
            text: "テスト",
            voice: activeVoice,
            profile: .init(numSteps: 12, schedule: .sway, style: .neutral, swayCoefficient: -1),
            maximumBytes: 64,
            onMilestone: { milestone in await milestoneCollector.append(milestone) }
        )
        let milestones = await milestoneCollector.values

        #expect(audio.wavBytes == Data("RIFFWAVE".utf8))
        #expect(audio.serverElapsedSeconds == 0.25)
        #expect(
            milestones == [
                .handshake,
                .firstAudioPayload,
                .completed(serverElapsedMilliseconds: 250, samplingSteps: 12),
            ])
    }

    @Test
    func readinessAndHTTPFailuresAreNormalized() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path == "/capabilities" {
                return try Self.response(
                    request,
                    body:
                        #"{"contract_version":1,"generation":"g1","ready":false,"readiness":"model_loading","voices":[]}"#
                )
            }
            return try Self.response(
                request, status: 503, body: #"{"detail":"private remote text"}"#)
        }
        let client = IrodoriClient(
            baseURL: try #require(URL(string: "https://unit.test")), session: stubSession())

        await #expect(throws: IrodoriClientError.remoteUnavailable) {
            _ = try await client.health()
        }
        await #expect(throws: IrodoriClientError.notReady) {
            _ = try await client.prepareVoice(configuredVoiceID: nil)
        }
    }

    @Test
    func malformedMetadataAndLargeResponsesAreNormalized() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path == "/health" {
                return try Self.response(request, body: "not-json")
            }
            return try Self.response(
                request,
                data: Data(repeating: 0x20, count: 1_048_577),
                contentType: "application/json"
            )
        }
        let client = IrodoriClient(
            baseURL: try #require(URL(string: "https://unit.test")),
            session: stubSession()
        )

        await #expect(throws: IrodoriClientError.invalidResponse) {
            _ = try await client.health()
        }
        await #expect(throws: IrodoriClientError.responseTooLarge) {
            _ = try await client.capabilities()
        }
    }

    @Test
    func streamProtocolAndRemoteErrorsAreNormalized() async throws {
        let voice = ActiveVoice(id: "v1", generation: "g1")
        let profile = SynthesisProfile(
            numSteps: 12,
            schedule: .sway,
            style: .neutral,
            swayCoefficient: -1
        )
        URLProtocolStub.handler = { request in
            try Self.response(
                request,
                data: Data(
                    (#"{"kind":"handshake","v":1,"max_chunk_size":16}"# + "\n"
                        + #"{"kind":"chunk","v":1,"index":0,"nbytes":0,"final":true,"elapsed":0,"error_code":"backpressure"}"#
                        + "\n").utf8
                ),
                contentType: "application/octet-stream"
            )
        }
        let client = IrodoriClient(
            baseURL: try #require(URL(string: "https://unit.test")),
            session: stubSession()
        )

        await #expect(throws: IrodoriClientError.remote(.backpressure)) {
            _ = try await client.synthesize(
                text: "テスト",
                voice: voice,
                profile: profile,
                maximumBytes: 64,
                onMilestone: { _ in }
            )
        }
        await #expect(throws: IrodoriClientError.invalidResponse) {
            _ = try await client.synthesize(
                text: "  ",
                voice: voice,
                profile: profile,
                maximumBytes: 64,
                onMilestone: { _ in }
            )
        }
    }

    @Test
    func largeStreamAndConfiguredSynthesizerProduceValidatedClip() async throws {
        let wave = Self.makeWave(sampleCount: 4_200)
        URLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/synthesize_stream":
                let header =
                    #"{"kind":"handshake","v":1,"max_chunk_size":10000}"# + "\n"
                    + #"{"kind":"chunk","v":1,"index":0,"nbytes":\#(wave.count),"final":true,"elapsed":0.5}"#
                    + "\n"
                return try Self.response(
                    request,
                    data: Data(header.utf8) + wave,
                    contentType: "application/octet-stream"
                )
            default:
                return try Self.response(request, status: 404, body: "{}")
            }
        }
        let client = IrodoriClient(
            baseURL: try #require(URL(string: "https://unit.test")),
            session: stubSession()
        )
        let synthesizer = ConfiguredIrodoriSynthesizer(
            client: client,
            voice: .init(id: "v1", generation: "g1"),
            profile: .init(
                numSteps: 12,
                schedule: .sway,
                style: .neutral,
                swayCoefficient: -1
            ),
            maximumBytes: 20_000,
            maximumDurationSeconds: 2
        )

        let clip = try await synthesizer.synthesize(
            text: "テスト",
            utteranceID: UUID(),
            onMilestone: { _ in }
        )
        #expect(clip.wavBytes == wave)
        #expect(clip.durationMilliseconds == 87.5)
    }

    @Test
    func streamHandshakeCannotExceedHealthAdvertisement() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path == "/health" {
                return try Self.response(
                    request,
                    body: #"{"status":"ok","model_loaded":true,"max_chunk_size":16}"#
                )
            }
            return try Self.response(
                request,
                data: Data(
                    (#"{"kind":"handshake","v":1,"max_chunk_size":32}"# + "\n"
                        + #"{"kind":"chunk","v":1,"index":0,"nbytes":0,"final":true,"elapsed":0}"#
                        + "\n").utf8
                ),
                contentType: "application/octet-stream"
            )
        }
        let client = IrodoriClient(
            baseURL: try #require(URL(string: "https://unit.test")),
            session: stubSession()
        )
        _ = try await client.health()

        await #expect(throws: IrodoriClientError.invalidResponse) {
            _ = try await client.synthesize(
                text: "テスト",
                voice: .init(id: "v1", generation: "g1"),
                profile: .init(
                    numSteps: 12,
                    schedule: .sway,
                    style: .neutral,
                    swayCoefficient: -1
                ),
                maximumBytes: 64,
                onMilestone: { _ in }
            )
        }
    }

    @Test
    func firstAudioMilestoneIsEmittedOnlyOnceAcrossMultipleChunks() async throws {
        URLProtocolStub.handler = { request in
            try Self.response(
                request,
                data: Data(
                    (#"{"kind":"handshake","v":1,"max_chunk_size":16}"# + "\n"
                        + #"{"kind":"chunk","v":1,"index":0,"nbytes":1,"final":false,"elapsed":0.1}"#
                        + "\na"
                        + #"{"kind":"chunk","v":1,"index":1,"nbytes":1,"final":true,"elapsed":0.2}"#
                        + "\nb").utf8
                ),
                contentType: "application/octet-stream"
            )
        }
        let collector = MilestoneCollector()
        let client = IrodoriClient(
            baseURL: try #require(URL(string: "https://unit.test")), session: stubSession())

        _ = try await client.synthesize(
            text: "test",
            voice: .init(id: "v1", generation: "g1"),
            profile: .init(numSteps: 12, schedule: .sway, style: .neutral, swayCoefficient: -1),
            maximumBytes: 64,
            onMilestone: { await collector.append($0) }
        )

        #expect(await collector.values.filter { $0 == .firstAudioPayload }.count == 1)
    }

    @Test
    func cancellingAStalledRequestPropagatesCancellation() async throws {
        let lifecycle = URLProtocolLifecycle()
        StallingURLProtocol.lifecycle = lifecycle
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StallingURLProtocol.self]
        let client = IrodoriClient(
            baseURL: try #require(URL(string: "https://unit.test")),
            session: URLSession(configuration: configuration)
        )
        let task = Task {
            try await client.synthesize(
                text: "停止",
                voice: .init(id: "v1", generation: "g1"),
                profile: .init(
                    numSteps: 12, schedule: .sway, style: .neutral, swayCoefficient: -1),
                maximumBytes: 64,
                onMilestone: { _ in }
            )
        }

        await lifecycle.waitUntilStarted()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        await lifecycle.waitUntilStopped()
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        _ request: URLRequest,
        status: Int = 200,
        body: String
    ) throws -> (HTTPURLResponse, Data) {
        try response(
            request, status: status, data: Data(body.utf8), contentType: "application/json")
    }

    private static func response(
        _ request: URLRequest,
        status: Int = 200,
        data: Data,
        contentType: String
    ) throws -> (HTTPURLResponse, Data) {
        let response = try #require(
            HTTPURLResponse(
                url: request.url ?? URL(filePath: "/"),
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType]
            ))
        return (response, data)
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func makeWave(sampleCount: Int) -> Data {
        let pcmCount = sampleCount * 2
        var data = Data(repeating: 0, count: 44 + pcmCount)
        data.replaceSubrange(0..<4, with: Data("RIFF".utf8))
        write(UInt32(data.count - 8), to: &data, at: 4)
        data.replaceSubrange(8..<12, with: Data("WAVEfmt ".utf8))
        write(UInt32(16), to: &data, at: 16)
        write(UInt16(1), to: &data, at: 20)
        write(UInt16(1), to: &data, at: 22)
        write(UInt32(48_000), to: &data, at: 24)
        write(UInt32(96_000), to: &data, at: 28)
        write(UInt16(2), to: &data, at: 32)
        write(UInt16(16), to: &data, at: 34)
        data.replaceSubrange(36..<40, with: Data("data".utf8))
        write(UInt32(pcmCount), to: &data, at: 40)
        return data
    }

    private static func write(_ value: UInt16, to data: inout Data, at offset: Int) {
        data.replaceSubrange(
            offset..<(offset + 2),
            with: [UInt8(value & 0xFF), UInt8(value >> 8)]
        )
    }

    private static func write(_ value: UInt32, to data: inout Data, at offset: Int) {
        data.replaceSubrange(
            offset..<(offset + 4),
            with: [
                UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF), UInt8(value >> 24),
            ]
        )
    }
}

private actor MilestoneCollector {
    private(set) var values = [SynthesisMilestone]()

    func append(_ milestone: SynthesisMilestone) {
        values.append(milestone)
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try #require(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class StallingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lifecycle: URLProtocolLifecycle?

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let lifecycle = Self.lifecycle {
            Task { await lifecycle.recordStarted() }
        }
    }

    override func stopLoading() {
        if let lifecycle = Self.lifecycle {
            Task { await lifecycle.recordStopped() }
        }
    }
}

private actor URLProtocolLifecycle {
    private var started = false
    private var stopped = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var stoppedContinuation: CheckedContinuation<Void, Never>?

    func recordStarted() {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
    }

    func recordStopped() {
        stopped = true
        stoppedContinuation?.resume()
        stoppedContinuation = nil
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func waitUntilStopped() async {
        guard !stopped else { return }
        await withCheckedContinuation { continuation in
            stoppedContinuation = continuation
        }
    }
}
