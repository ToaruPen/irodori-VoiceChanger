import AVFAudio
import CoreMedia
import Foundation
import IrodoriVoiceChangerCore
import Speech

public struct SpeechAudioRange: Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double

    public init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public struct AppleSpeechResultMapper: Sendable {
    private let idGenerator: @Sendable () -> UUID
    private var activeUtteranceID: UUID?
    private var speechEnded = false
    private var previousText: String?
    private var revisionCount = 0
    private var activeRangeStart: Double?
    private var lastFinalRangeEnd: Double?

    public init(idGenerator: @escaping @Sendable () -> UUID = UUID.init) {
        self.idGenerator = idGenerator
    }

    public mutating func mapDetection(
        speechDetected: Bool,
        range: SpeechAudioRange? = nil
    ) -> [SpeechEvent] {
        if let range, let lastFinalRangeEnd, range.startSeconds < lastFinalRangeEnd {
            return []
        }
        if speechDetected {
            guard activeUtteranceID == nil else { return [] }
            let id = beginUtterance(rangeStart: range?.startSeconds)
            return [.speechStarted(id)]
        }
        if let range, let activeRangeStart, range.endSeconds <= activeRangeStart {
            return []
        }
        guard let id = activeUtteranceID, !speechEnded else { return [] }
        speechEnded = true
        return [.speechEnded(id)]
    }

    public mutating func mapTranscription(
        text: String,
        isFinal: Bool,
        range: SpeechAudioRange? = nil
    ) -> [SpeechEvent] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        if let range {
            if let activeRangeStart, range.endSeconds <= activeRangeStart {
                return []
            }
            if activeUtteranceID == nil,
                let lastFinalRangeEnd,
                range.endSeconds <= lastFinalRangeEnd
            {
                return []
            }
        }

        var events = [SpeechEvent]()
        let id: UUID
        if let activeUtteranceID {
            id = activeUtteranceID
        } else {
            id = beginUtterance(rangeStart: range?.startSeconds)
            events.append(.speechStarted(id))
        }
        if let previousText, previousText != normalized {
            revisionCount += 1
        }
        previousText = normalized
        if isFinal {
            if !speechEnded {
                events.append(.speechEnded(id))
            }
            events.append(.final(id, text: normalized, revisionCount: revisionCount))
            if let range {
                lastFinalRangeEnd = max(lastFinalRangeEnd ?? 0, range.endSeconds)
            }
            reset()
        } else {
            events.append(.partial(id, text: normalized, revisionCount: revisionCount))
        }
        return events
    }

    private mutating func beginUtterance(rangeStart: Double? = nil) -> UUID {
        let id = idGenerator()
        activeUtteranceID = id
        speechEnded = false
        previousText = nil
        revisionCount = 0
        activeRangeStart = rangeStart
        return id
    }

    private mutating func reset() {
        activeUtteranceID = nil
        speechEnded = false
        previousText = nil
        revisionCount = 0
        activeRangeStart = nil
    }
}

public enum AppleSpeechSessionError: Error, Equatable, Sendable {
    case unavailable
    case unsupportedLocale
    case assetUnavailable
    case noCompatibleAudioFormat
    case alreadyRunning
    case eventBufferOverflow
}

public enum AppleSpeechAssetState: String, Equatable, Sendable {
    case unsupported
    case supported
    case downloading
    case installed
}

public struct AppleSpeechInspection: Equatable, Sendable {
    public let localeSupported: Bool
    public let assetState: AppleSpeechAssetState
}

public actor AppleSpeechSession {
    public nonisolated let audioFormat: AVAudioFormat

    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let detector: SpeechDetector
    private var running = false

    private init(
        audioFormat: AVAudioFormat,
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        detector: SpeechDetector
    ) {
        self.audioFormat = audioFormat
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.detector = detector
    }

    public static func prepare(
        localeIdentifier: String,
        sensitivity: DetectorSensitivity,
        installAssets: Bool = true
    ) async throws -> AppleSpeechSession {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechSessionError.unavailable
        }
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        else {
            throw AppleSpeechSessionError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: sensitivity.appleSpeechLevel),
            reportResults: true
        )
        let modules: [any SpeechModule] = [transcriber, detector]
        let initialStatus = await AssetInventory.status(forModules: modules)
        if initialStatus != .installed {
            guard installAssets, initialStatus == .supported,
                let request = try await AssetInventory.assetInstallationRequest(
                    supporting: modules)
            else {
                throw AppleSpeechSessionError.assetUnavailable
            }
            try await request.downloadAndInstall()
            guard await AssetInventory.status(forModules: modules) == .installed else {
                throw AppleSpeechSessionError.assetUnavailable
            }
        }
        _ = try await AssetInventory.reserve(locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        else {
            throw AppleSpeechSessionError.noCompatibleAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: format)
        return AppleSpeechSession(
            audioFormat: format,
            analyzer: analyzer,
            transcriber: transcriber,
            detector: detector
        )
    }

    public static func inspect(
        localeIdentifier: String,
        sensitivity: DetectorSensitivity
    ) async -> AppleSpeechInspection {
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        else {
            return AppleSpeechInspection(localeSupported: false, assetState: .unsupported)
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: sensitivity.appleSpeechLevel),
            reportResults: true
        )
        let status = await AssetInventory.status(forModules: [transcriber, detector])
        return AppleSpeechInspection(
            localeSupported: true,
            assetState: status.publicState
        )
    }

    public func events<InputSequence>(
        from inputSequence: InputSequence
    ) throws -> AsyncThrowingStream<SpeechEvent, Error>
    where InputSequence: AsyncSequence & Sendable, InputSequence.Element == AnalyzerInput {
        guard !running else { throw AppleSpeechSessionError.alreadyRunning }
        running = true
        let analyzer = analyzer
        let transcriber = transcriber
        let detector = detector
        let analysisStartNanoseconds = DispatchTime.now().uptimeNanoseconds

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let task = Task {
                let mapper = SpeechMappingActor()
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await result in transcriber.results {
                                let events = await mapper.mapTranscription(
                                    text: String(result.text.characters),
                                    isFinal: result.isFinal,
                                    range: result.range.audioRange
                                )
                                for event in events {
                                    if let timing = timingEvent(
                                        for: event,
                                        resultRange: result.range,
                                        analysisStartNanoseconds: analysisStartNanoseconds
                                    ) {
                                        try yieldSpeechEvent(timing, to: continuation)
                                    }
                                    try yieldSpeechEvent(event, to: continuation)
                                }
                            }
                        }
                        group.addTask {
                            for try await result in detector.results {
                                let events = await mapper.mapDetection(
                                    speechDetected: result.speechDetected,
                                    range: result.range.audioRange)
                                for event in events {
                                    if let timing = timingEvent(
                                        for: event,
                                        resultRange: result.range,
                                        analysisStartNanoseconds: analysisStartNanoseconds
                                    ) {
                                        try yieldSpeechEvent(timing, to: continuation)
                                    }
                                    try yieldSpeechEvent(event, to: continuation)
                                }
                            }
                        }
                        group.addTask {
                            _ = try await analyzer.analyzeSequence(inputSequence)
                            try await analyzer.finalizeAndFinishThroughEndOfInput()
                        }
                        try await group.waitForAll()
                    }
                    continuation.finish()
                } catch is CancellationError {
                    await analyzer.cancelAndFinishNow()
                    continuation.finish()
                } catch {
                    await analyzer.cancelAndFinishNow()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func cancel() async {
        await analyzer.cancelAndFinishNow()
        running = false
    }

    public func finalizeConsumedAudio() async throws {
        try await analyzer.finalize(through: nil)
    }
}

func yieldSpeechEvent(
    _ event: SpeechEvent,
    to continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation
) throws {
    switch continuation.yield(event) {
    case .enqueued:
        return
    case .dropped:
        throw AppleSpeechSessionError.eventBufferOverflow
    case .terminated:
        throw CancellationError()
    @unknown default:
        throw AppleSpeechSessionError.eventBufferOverflow
    }
}

private func timingEvent(
    for event: SpeechEvent,
    resultRange: CMTimeRange,
    analysisStartNanoseconds: UInt64
) -> SpeechEvent? {
    let id: UUID
    let kind: SpeechTimingKind
    switch event {
    case .partial(let utteranceID, _, _):
        id = utteranceID
        kind = .partial
    case .final(let utteranceID, _, _):
        id = utteranceID
        kind = .final
    case .speechEnded(let utteranceID):
        id = utteranceID
        kind = .speechEnd
    default:
        return nil
    }
    let audioEndSeconds = CMTimeGetSeconds(CMTimeRangeGetEnd(resultRange))
    guard audioEndSeconds.isFinite, audioEndSeconds >= 0 else { return nil }
    let now = DispatchTime.now().uptimeNanoseconds
    let elapsedMilliseconds = Double(now - analysisStartNanoseconds) / 1_000_000
    let deliveryMilliseconds = max(0, elapsedMilliseconds - audioEndSeconds * 1_000)
    return .timing(id, kind: kind, deliveryMilliseconds: deliveryMilliseconds)
}

private actor SpeechMappingActor {
    private var mapper = AppleSpeechResultMapper()

    func mapDetection(
        speechDetected: Bool,
        range: SpeechAudioRange
    ) -> [SpeechEvent] {
        mapper.mapDetection(speechDetected: speechDetected, range: range)
    }

    func mapTranscription(
        text: String,
        isFinal: Bool,
        range: SpeechAudioRange
    ) -> [SpeechEvent] {
        mapper.mapTranscription(text: text, isFinal: isFinal, range: range)
    }
}

private extension CMTimeRange {
    var audioRange: SpeechAudioRange {
        SpeechAudioRange(
            startSeconds: CMTimeGetSeconds(start),
            endSeconds: CMTimeGetSeconds(CMTimeRangeGetEnd(self))
        )
    }
}

private extension DetectorSensitivity {
    var appleSpeechLevel: SpeechDetector.SensitivityLevel {
        switch self {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }
}

private extension AssetInventory.Status {
    var publicState: AppleSpeechAssetState {
        switch self {
        case .unsupported: .unsupported
        case .supported: .supported
        case .downloading: .downloading
        case .installed: .installed
        @unknown default: .unsupported
        }
    }
}
