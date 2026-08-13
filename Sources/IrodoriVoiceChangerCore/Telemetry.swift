import Foundation

public enum TelemetryEventName: String, Codable, CaseIterable, Sendable {
    case sessionStarted = "session_started"
    case sessionReady = "session_ready"
    case sessionStopped = "session_stopped"
    case speechStarted = "speech_started"
    case speechEnded = "speech_ended"
    case speechEndTiming = "speech_end_timing"
    case asrPartial = "asr_partial"
    case asrFinal = "asr_final"
    case asrPartialTiming = "asr_partial_timing"
    case asrFinalTiming = "asr_final_timing"
    case utteranceCommitted = "utterance_committed"
    case utteranceRewriteRejected = "utterance_rewrite_rejected"
    case utteranceDropped = "utterance_dropped"
    case shadowPrefixCandidate = "shadow_prefix_candidate"
    case shadowPrefixRewrite = "shadow_prefix_rewrite"
    case shadowPrefixRollback = "shadow_prefix_rollback"
    case shadowFinalComparison = "shadow_final_comparison"
    case shadowEndpointEnabled = "shadow_endpoint_enabled"
    case shadowEndpointCandidate = "shadow_endpoint_candidate"
    case shadowEndpointSpeechResumed = "shadow_endpoint_speech_resumed"
    case shadowEndpointFinalComparison = "shadow_endpoint_final_comparison"
    case shadowEndpointOverflow = "shadow_endpoint_overflow"
    case shadowEndpointFinalizeRequested = "shadow_endpoint_finalize_requested"
    case shadowEndpointFinalizeCompleted = "shadow_endpoint_finalize_completed"
    case shadowEndpointFinalizeFailed = "shadow_endpoint_finalize_failed"
    case semanticEndpointRequested = "semantic_endpoint_requested"
    case semanticEndpointCompleted = "semantic_endpoint_completed"
    case semanticEndpointFailed = "semantic_endpoint_failed"
    case shadowSynthesisStarted = "shadow_synthesis_started"
    case shadowSynthesisHandshake = "shadow_synthesis_handshake"
    case shadowSynthesisFirstAudio = "shadow_synthesis_first_audio"
    case shadowSynthesisCompleted = "shadow_synthesis_completed"
    case shadowSynthesisCancelled = "shadow_synthesis_cancelled"
    case shadowSynthesisFailed = "shadow_synthesis_failed"
    case shadowSynthesisFinalComparison = "shadow_synthesis_final_comparison"
    case requestStarted = "request_started"
    case streamHandshake = "stream_handshake"
    case firstAudioPayload = "first_audio_payload"
    case requestCompleted = "request_completed"
    case playbackEnqueued = "playback_enqueued"
    case playbackStarted = "playback_started"
    case playbackCompleted = "playback_completed"
    case queueUnderrun = "queue_underrun"
    case inputDropped = "input_dropped"
    case preflightCompleted = "preflight_completed"
    case operationFailed = "operation_failed"
}

public struct TelemetryMetrics: Codable, Equatable, Sendable {
    public let durationMilliseconds: Double?
    public let audioDurationMilliseconds: Double?
    public let serverDurationMilliseconds: Double?
    public let queueDepth: Int?
    public let byteCount: Int?
    public let partialRevisionCount: Int?
    public let samplingSteps: Int?
    public let sourceLatencyMilliseconds: Double?
    public let dropCount: Int?
    public let telemetryFailureCount: Int?
    public let endpointSilenceMilliseconds: Int?
    public let shadowCandidatePresent: Bool?
    public let shadowCandidateMatchRatio: Double?
    public let shadowFinalCoverageRatio: Double?
    public let semanticProbabilityBucket: Int?
    public let semanticTurnComplete: Bool?

    public init(
        durationMilliseconds: Double? = nil,
        audioDurationMilliseconds: Double? = nil,
        serverDurationMilliseconds: Double? = nil,
        queueDepth: Int? = nil,
        byteCount: Int? = nil,
        partialRevisionCount: Int? = nil,
        samplingSteps: Int? = nil,
        sourceLatencyMilliseconds: Double? = nil,
        dropCount: Int? = nil,
        telemetryFailureCount: Int? = nil,
        endpointSilenceMilliseconds: Int? = nil,
        shadowCandidatePresent: Bool? = nil,
        shadowCandidateMatchRatio: Double? = nil,
        shadowFinalCoverageRatio: Double? = nil,
        semanticProbabilityBucket: Int? = nil,
        semanticTurnComplete: Bool? = nil
    ) {
        self.durationMilliseconds = durationMilliseconds
        self.audioDurationMilliseconds = audioDurationMilliseconds
        self.serverDurationMilliseconds = serverDurationMilliseconds
        self.queueDepth = queueDepth
        self.byteCount = byteCount
        self.partialRevisionCount = partialRevisionCount
        self.samplingSteps = samplingSteps
        self.sourceLatencyMilliseconds = sourceLatencyMilliseconds
        self.dropCount = dropCount
        self.telemetryFailureCount = telemetryFailureCount
        self.endpointSilenceMilliseconds = endpointSilenceMilliseconds
        self.shadowCandidatePresent = shadowCandidatePresent
        self.shadowCandidateMatchRatio = shadowCandidateMatchRatio
        self.shadowFinalCoverageRatio = shadowFinalCoverageRatio
        self.semanticProbabilityBucket = semanticProbabilityBucket
        self.semanticTurnComplete = semanticTurnComplete
    }

    private enum CodingKeys: String, CodingKey {
        case durationMilliseconds = "duration_milliseconds"
        case audioDurationMilliseconds = "audio_duration_milliseconds"
        case serverDurationMilliseconds = "server_duration_milliseconds"
        case queueDepth = "queue_depth"
        case byteCount = "byte_count"
        case partialRevisionCount = "partial_revision_count"
        case samplingSteps = "sampling_steps"
        case sourceLatencyMilliseconds = "source_latency_milliseconds"
        case dropCount = "drop_count"
        case telemetryFailureCount = "telemetry_failure_count"
        case endpointSilenceMilliseconds = "endpoint_silence_milliseconds"
        case shadowCandidatePresent = "shadow_candidate_present"
        case shadowCandidateMatchRatio = "shadow_candidate_match_ratio"
        case shadowFinalCoverageRatio = "shadow_final_coverage_ratio"
        case semanticProbabilityBucket = "semantic_probability_bucket"
        case semanticTurnComplete = "semantic_turn_complete"
    }
}

public struct TelemetryEvent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let utteranceID: UUID?
    public let timestampNanoseconds: UInt64
    public let name: TelemetryEventName
    public let stage: PipelineStage?
    public let errorCode: StableErrorCode?
    public let metrics: TelemetryMetrics

    public init(
        sessionID: UUID,
        utteranceID: UUID?,
        timestampNanoseconds: UInt64,
        name: TelemetryEventName,
        stage: PipelineStage? = nil,
        errorCode: StableErrorCode? = nil,
        metrics: TelemetryMetrics = .init()
    ) {
        self.schemaVersion = 1
        self.sessionID = sessionID
        self.utteranceID = utteranceID
        self.timestampNanoseconds = timestampNanoseconds
        self.name = name
        self.stage = stage
        self.errorCode = errorCode
        self.metrics = metrics
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case utteranceID = "utterance_id"
        case timestampNanoseconds = "timestamp_nanoseconds"
        case name
        case stage
        case errorCode = "error_code"
        case metrics
    }
}

public extension JSONEncoder {
    static var telemetry: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public extension JSONDecoder {
    static var telemetry: JSONDecoder {
        JSONDecoder()
    }
}

public enum TelemetryWriteResult: Sendable {
    case written
    case unavailable
}

public protocol TelemetryRecording: Sendable {
    func record(_ event: TelemetryEvent) async -> TelemetryWriteResult
}

public actor SessionTelemetryRecorder: TelemetryRecording {
    private let base: any TelemetryRecording
    private let onFirstUnavailable: @Sendable () async -> Void
    private var failureCount = 0

    public init(
        base: any TelemetryRecording,
        onFirstUnavailable: @escaping @Sendable () async -> Void
    ) {
        self.base = base
        self.onFirstUnavailable = onFirstUnavailable
    }

    public func record(_ event: TelemetryEvent) async -> TelemetryWriteResult {
        let eventToWrite: TelemetryEvent
        if event.name == .sessionStopped, failureCount > 0 {
            eventToWrite = TelemetryEvent(
                sessionID: event.sessionID,
                utteranceID: event.utteranceID,
                timestampNanoseconds: event.timestampNanoseconds,
                name: event.name,
                stage: event.stage,
                errorCode: event.errorCode,
                metrics: .init(telemetryFailureCount: failureCount)
            )
        } else {
            eventToWrite = event
        }
        let result = await base.record(eventToWrite)
        if case .unavailable = result {
            failureCount += 1
            if failureCount == 1 {
                await onFirstUnavailable()
            }
        }
        return result
    }
}

public actor JSONLTelemetryRecorder: TelemetryRecording {
    private let directory: URL
    private let maximumFileBytes: Int
    private let retainedFileCount: Int
    private let fileManager: FileManager

    public init(
        directory: URL,
        maximumFileBytes: Int,
        retainedFileCount: Int,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.maximumFileBytes = maximumFileBytes
        self.retainedFileCount = retainedFileCount
        self.fileManager = fileManager
    }

    public func record(_ event: TelemetryEvent) -> TelemetryWriteResult {
        do {
            var line = try JSONEncoder.telemetry.encode(event)
            line.append(0x0A)
            try prepareDirectory()
            if try currentFileSize() + line.count > maximumFileBytes {
                try rotateFiles()
            }
            try append(line)
            return .written
        } catch {
            return .unavailable
        }
    }

    private var currentFile: URL {
        directory.appending(path: "events.jsonl")
    }

    private func archiveFile(index: Int) -> URL {
        directory.appending(path: "events.\(index).jsonl")
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func currentFileSize() throws -> Int {
        guard fileManager.fileExists(atPath: currentFile.path) else {
            return 0
        }
        let attributes = try fileManager.attributesOfItem(atPath: currentFile.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private func rotateFiles() throws {
        let archiveCount = max(0, retainedFileCount - 1)
        guard archiveCount > 0 else {
            if fileManager.fileExists(atPath: currentFile.path) {
                try fileManager.removeItem(at: currentFile)
            }
            return
        }

        let oldest = archiveFile(index: archiveCount)
        if fileManager.fileExists(atPath: oldest.path) {
            try fileManager.removeItem(at: oldest)
        }
        if archiveCount > 1 {
            for index in stride(from: archiveCount - 1, through: 1, by: -1) {
                let source = archiveFile(index: index)
                guard fileManager.fileExists(atPath: source.path) else {
                    continue
                }
                try fileManager.moveItem(at: source, to: archiveFile(index: index + 1))
            }
        }
        if fileManager.fileExists(atPath: currentFile.path) {
            try fileManager.moveItem(at: currentFile, to: archiveFile(index: 1))
        }
    }

    private func append(_ data: Data) throws {
        if !fileManager.fileExists(atPath: currentFile.path) {
            guard
                fileManager.createFile(
                    atPath: currentFile.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: currentFile.path)
        let handle = try FileHandle(forWritingTo: currentFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

public struct MetricSummary: Codable, Equatable, Sendable {
    public let count: Int
    public let minimum: Double
    public let p50: Double
    public let p95: Double
    public let maximum: Double

    public init?(values: [Double]) {
        guard !values.isEmpty else {
            return nil
        }
        let sorted = values.sorted()
        self.count = sorted.count
        self.minimum = sorted[0]
        self.p50 = Self.nearestRank(percentile: 0.50, sortedValues: sorted)
        self.p95 = Self.nearestRank(percentile: 0.95, sortedValues: sorted)
        self.maximum = sorted[sorted.count - 1]
    }

    private static func nearestRank(percentile: Double, sortedValues: [Double]) -> Double {
        let rank = max(1, Int(ceil(percentile * Double(sortedValues.count))))
        return sortedValues[rank - 1]
    }
}
