import Foundation

public enum LatencyMetricName: String, Codable, CaseIterable, Sendable {
    case audioToFirstPartialDelivery = "audio_to_first_partial_delivery_ms"
    case audioToSpeechEndDelivery = "audio_to_speech_end_delivery_ms"
    case audioToFinalDelivery = "audio_to_final_delivery_ms"
    case audioEndToPlayback = "audio_end_to_playback_ms"
    case asrFinalToRequest = "asr_final_to_request_ms"
    case requestToHandshake = "request_to_handshake_ms"
    case requestToFirstAudio = "request_to_first_audio_ms"
    case requestToComplete = "request_to_complete_ms"
    case serverElapsed = "server_elapsed_ms"
    case requestMinusServer = "request_minus_server_ms"
    case playbackQueueWait = "playback_queue_wait_ms"
    case speechEndToPlayback = "speech_end_to_playback_ms"
    case speechStartToPlayback = "speech_start_to_playback_ms"
    case synthesisCompleteToPlayback = "synthesis_complete_to_playback_ms"
    case playbackGap = "playback_gap_ms"
    case realTimeFactor = "real_time_factor"
    case lifecyclePreflight = "lifecycle_preflight_ms"
    case speechPreflight = "speech_preflight_ms"
    case irodoriPreflight = "irodori_preflight_ms"
    case coreAudioPreflight = "core_audio_preflight_ms"
    case speechStartToShadowCandidate = "speech_start_to_shadow_candidate_ms"
    case shadowCandidateToFinal = "shadow_candidate_to_final_ms"
    case shadowCandidateMatchRatio = "shadow_candidate_match_ratio"
    case shadowFinalCoverageRatio = "shadow_final_coverage_ratio"
    case endpointCandidateToFinal = "endpoint_candidate_to_final_ms"
    case endpointCandidateMatchRatio = "endpoint_candidate_match_ratio"
    case endpointFinalCoverageRatio = "endpoint_final_coverage_ratio"
    case endpointFinalizeDuration = "endpoint_finalize_duration_ms"
    case semanticInferenceDuration = "semantic_inference_duration_ms"
    case shadowSynthesisRequestToHandshake = "shadow_synthesis_request_to_handshake_ms"
    case shadowSynthesisRequestToFirstAudio = "shadow_synthesis_request_to_first_audio_ms"
    case shadowSynthesisRequestToComplete = "shadow_synthesis_request_to_complete_ms"
    case shadowSynthesisServerElapsed = "shadow_synthesis_server_elapsed_ms"
    case shadowSynthesisRequestMinusServer = "shadow_synthesis_request_minus_server_ms"
    case shadowSynthesisCandidateMatchRatio = "shadow_synthesis_candidate_match_ratio"
    case shadowSynthesisFinalCoverageRatio = "shadow_synthesis_final_coverage_ratio"
}

public struct LatencyMetricCollection: Codable, Equatable, Sendable {
    private let storage: [LatencyMetricName: MetricSummary]

    public init(_ storage: [LatencyMetricName: MetricSummary]) {
        self.storage = storage
    }

    public subscript(name: LatencyMetricName) -> MetricSummary? {
        storage[name]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (name, summary) in storage {
            try container.encode(summary, forKey: DynamicCodingKey(name.rawValue))
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var values = [LatencyMetricName: MetricSummary]()
        for key in container.allKeys {
            guard let name = LatencyMetricName(rawValue: key.stringValue) else { continue }
            values[name] = try container.decode(MetricSummary.self, forKey: key)
        }
        storage = values
    }
}

public struct TelemetryReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let utteranceCount: Int
    public let playbackCompletedCount: Int
    public let droppedCount: Int
    public let failureCount: Int
    public let inputDropCount: Int
    public let maximumQueueDepth: Int
    public let queueUnderrunCount: Int
    public let partialRevisionCount: Int
    public let rewriteRejectedCount: Int
    public let shadowCandidateUtteranceCount: Int
    public let shadowRewriteCount: Int
    public let shadowRollbackCount: Int
    public let endpointShadowSilenceMilliseconds: Int?
    public let endpointShadowCandidateCount: Int
    public let endpointShadowCandidatePresentCount: Int
    public let endpointShadowSpeechResumedCount: Int
    public let endpointFinalizeRequestedCount: Int
    public let endpointFinalizeCompletedCount: Int
    public let endpointFinalizeFailureCount: Int
    public let semanticEndpointRequestedCount: Int
    public let semanticEndpointCompleteCount: Int
    public let semanticEndpointIncompleteCount: Int
    public let semanticEndpointFailureCount: Int
    public let shadowSynthesisStartedCount: Int
    public let shadowSynthesisCompletedCount: Int
    public let shadowSynthesisCancelledCount: Int
    public let shadowSynthesisFailureCount: Int
    public let telemetryFailureCount: Int
    public let incomplete: Bool
    public let metrics: LatencyMetricCollection

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case utteranceCount = "utterance_count"
        case playbackCompletedCount = "playback_completed_count"
        case droppedCount = "dropped_count"
        case failureCount = "failure_count"
        case inputDropCount = "input_drop_count"
        case maximumQueueDepth = "maximum_queue_depth"
        case queueUnderrunCount = "queue_underrun_count"
        case partialRevisionCount = "partial_revision_count"
        case rewriteRejectedCount = "rewrite_rejected_count"
        case shadowCandidateUtteranceCount = "shadow_candidate_utterance_count"
        case shadowRewriteCount = "shadow_rewrite_count"
        case shadowRollbackCount = "shadow_rollback_count"
        case endpointShadowSilenceMilliseconds = "endpoint_shadow_silence_milliseconds"
        case endpointShadowCandidateCount = "endpoint_shadow_candidate_count"
        case endpointShadowCandidatePresentCount = "endpoint_shadow_candidate_present_count"
        case endpointShadowSpeechResumedCount = "endpoint_shadow_speech_resumed_count"
        case endpointFinalizeRequestedCount = "endpoint_finalize_requested_count"
        case endpointFinalizeCompletedCount = "endpoint_finalize_completed_count"
        case endpointFinalizeFailureCount = "endpoint_finalize_failure_count"
        case semanticEndpointRequestedCount = "semantic_endpoint_requested_count"
        case semanticEndpointCompleteCount = "semantic_endpoint_complete_count"
        case semanticEndpointIncompleteCount = "semantic_endpoint_incomplete_count"
        case semanticEndpointFailureCount = "semantic_endpoint_failure_count"
        case shadowSynthesisStartedCount = "shadow_synthesis_started_count"
        case shadowSynthesisCompletedCount = "shadow_synthesis_completed_count"
        case shadowSynthesisCancelledCount = "shadow_synthesis_cancelled_count"
        case shadowSynthesisFailureCount = "shadow_synthesis_failure_count"
        case telemetryFailureCount = "telemetry_failure_count"
        case incomplete
        case metrics
    }
}

public enum TelemetryReportBuilder {
    public static func latestSessionID(events: [TelemetryEvent]) -> UUID? {
        events.last?.sessionID
    }

    public static func build(events: [TelemetryEvent], sessionID: UUID) -> TelemetryReport {
        let sessionEvents = events.filter { $0.sessionID == sessionID }
        let utteranceIDs = Set(
            sessionEvents.compactMap { event in
                event.name == .asrFinal ? event.utteranceID : nil
            })
        let timelines = eventTimelines(sessionEvents)

        var samples = [LatencyMetricName: [Double]]()
        collectSourceTimings(sessionEvents, into: &samples)
        collectRequestMetrics(sessionEvents, into: &samples)
        collectPreflightMetrics(sessionEvents, into: &samples)
        collectTimelineMetrics(timelines, into: &samples)
        collectAudioEndToPlayback(sessionEvents, timelines: timelines, into: &samples)
        collectRealTimeFactors(sessionEvents, into: &samples)
        collectPlaybackGaps(sessionEvents, into: &samples)
        collectShadowMetrics(sessionEvents, timelines: timelines, into: &samples)
        collectEndpointShadowMetrics(sessionEvents, into: &samples)
        collectEndpointFinalizationMetrics(sessionEvents, into: &samples)
        collectSemanticEndpointMetrics(sessionEvents, into: &samples)
        collectShadowSynthesisMetrics(sessionEvents, timelines: timelines, into: &samples)
        let summaries = samples.compactMapValues(MetricSummary.init(values:))
        let completed = sessionEvents.filter { $0.name == .playbackCompleted }.count
        let dropped = sessionEvents.filter { $0.name == .utteranceDropped }.count
        let failures = sessionEvents.filter { $0.name == .operationFailed }.count
        let inputDrops = sessionEvents.compactMap(\.metrics.dropCount).reduce(0, +)
        let maximumQueueDepth = sessionEvents.compactMap(\.metrics.queueDepth).max() ?? 0
        let underruns = sessionEvents.filter { $0.name == .queueUnderrun }.count
        let partialRevisions =
            sessionEvents
            .filter { $0.name == .asrFinal }
            .compactMap(\.metrics.partialRevisionCount)
            .reduce(0, +)
        let rewrites = sessionEvents.filter { $0.name == .utteranceRewriteRejected }.count
        let shadowCandidateUtterances = Set(
            sessionEvents.compactMap { event in
                event.name == .shadowPrefixCandidate ? event.utteranceID : nil
            })
        let shadowRewrites = sessionEvents.filter { $0.name == .shadowPrefixRewrite }.count
        let shadowRollbacks = sessionEvents.filter { $0.name == .shadowPrefixRollback }.count
        let endpoint = endpointSummary(sessionEvents)
        let semantic = semanticEndpointSummary(sessionEvents)
        let shadowSynthesisStarted = sessionEvents.filter {
            $0.name == .shadowSynthesisStarted
        }.count
        let shadowSynthesisCompleted = sessionEvents.filter {
            $0.name == .shadowSynthesisCompleted
        }.count
        let shadowSynthesisCancelled = sessionEvents.filter {
            $0.name == .shadowSynthesisCancelled
        }.count
        let shadowSynthesisFailures = sessionEvents.filter {
            $0.name == .shadowSynthesisFailed
        }.count
        let telemetryFailures = sessionEvents.compactMap(\.metrics.telemetryFailureCount).reduce(
            0, +)
        let sessionStopped = sessionEvents.contains { $0.name == .sessionStopped }
        let synthesisObserved = sessionEvents.contains { $0.name == .requestStarted }
        return TelemetryReport(
            schemaVersion: 1,
            sessionID: sessionID,
            utteranceCount: utteranceIDs.count,
            playbackCompletedCount: completed,
            droppedCount: dropped,
            failureCount: failures,
            inputDropCount: inputDrops,
            maximumQueueDepth: maximumQueueDepth,
            queueUnderrunCount: underruns,
            partialRevisionCount: partialRevisions,
            rewriteRejectedCount: rewrites,
            shadowCandidateUtteranceCount: shadowCandidateUtterances.count,
            shadowRewriteCount: shadowRewrites,
            shadowRollbackCount: shadowRollbacks,
            endpointShadowSilenceMilliseconds: endpoint.silenceMilliseconds,
            endpointShadowCandidateCount: endpoint.candidateCount,
            endpointShadowCandidatePresentCount: endpoint.candidatePresentCount,
            endpointShadowSpeechResumedCount: endpoint.speechResumedCount,
            endpointFinalizeRequestedCount: endpoint.finalizeRequestedCount,
            endpointFinalizeCompletedCount: endpoint.finalizeCompletedCount,
            endpointFinalizeFailureCount: endpoint.finalizeFailureCount,
            semanticEndpointRequestedCount: semantic.requestedCount,
            semanticEndpointCompleteCount: semantic.completeCount,
            semanticEndpointIncompleteCount: semantic.incompleteCount,
            semanticEndpointFailureCount: semantic.failureCount,
            shadowSynthesisStartedCount: shadowSynthesisStarted,
            shadowSynthesisCompletedCount: shadowSynthesisCompleted,
            shadowSynthesisCancelledCount: shadowSynthesisCancelled,
            shadowSynthesisFailureCount: shadowSynthesisFailures,
            telemetryFailureCount: telemetryFailures,
            incomplete: !sessionStopped
                || telemetryFailures > 0
                || endpoint.finalizeFailureCount > 0
                || endpoint.incomplete
                || semantic.incomplete
                || (synthesisObserved && completed + dropped + failures < utteranceIDs.count),
            metrics: LatencyMetricCollection(summaries)
        )
    }

    private static func eventTimelines(
        _ events: [TelemetryEvent]
    ) -> [UUID: [TelemetryEventName: UInt64]] {
        var timelines = [UUID: [TelemetryEventName: UInt64]]()
        for event in events {
            guard let utteranceID = event.utteranceID else { continue }
            if timelines[utteranceID]?[event.name] == nil {
                timelines[utteranceID, default: [:]][event.name] = event.timestampNanoseconds
            }
        }
        return timelines
    }

    private struct EndpointSummary {
        let silenceMilliseconds: Int?
        let candidateCount: Int
        let candidatePresentCount: Int
        let speechResumedCount: Int
        let finalizeRequestedCount: Int
        let finalizeCompletedCount: Int
        let finalizeFailureCount: Int
        let incomplete: Bool
    }

    private struct SemanticEndpointSummary {
        let requestedCount: Int
        let completeCount: Int
        let incompleteCount: Int
        let failureCount: Int
        let incomplete: Bool
    }

    private static func semanticEndpointSummary(
        _ events: [TelemetryEvent]
    ) -> SemanticEndpointSummary {
        let requested = events.filter { $0.name == .semanticEndpointRequested }.count
        let completed = events.filter { $0.name == .semanticEndpointCompleted }
        let failures = events.filter { $0.name == .semanticEndpointFailed }.count
        return SemanticEndpointSummary(
            requestedCount: requested,
            completeCount: completed.filter { $0.metrics.semanticTurnComplete == true }.count,
            incompleteCount: completed.filter { $0.metrics.semanticTurnComplete == false }.count,
            failureCount: failures,
            incomplete: failures > 0 || requested != completed.count + failures
        )
    }

    private static func endpointSummary(_ events: [TelemetryEvent]) -> EndpointSummary {
        let candidates = events.filter { $0.name == .shadowEndpointCandidate }
        return EndpointSummary(
            silenceMilliseconds: endpointSilenceMilliseconds(events),
            candidateCount: candidates.count,
            candidatePresentCount: candidates.filter {
                $0.metrics.shadowCandidatePresent == true
            }.count,
            speechResumedCount: events.filter { $0.name == .shadowEndpointSpeechResumed }.count,
            finalizeRequestedCount: events.filter {
                $0.name == .shadowEndpointFinalizeRequested
            }.count,
            finalizeCompletedCount: events.filter {
                $0.name == .shadowEndpointFinalizeCompleted
            }.count,
            finalizeFailureCount: events.filter { $0.name == .shadowEndpointFinalizeFailed }.count,
            incomplete: endpointShadowIncomplete(events)
        )
    }

    private static func endpointShadowIncomplete(_ events: [TelemetryEvent]) -> Bool {
        guard !events.contains(where: { $0.name == .shadowEndpointOverflow }) else { return true }
        let candidates = Set(
            events.compactMap { event in
                event.name == .shadowEndpointCandidate ? event.utteranceID : nil
            })
        let comparisons = Set(
            events.compactMap { event in
                event.name == .shadowEndpointFinalComparison ? event.utteranceID : nil
            })
        return !candidates.isSubset(of: comparisons)
    }

    private static func endpointSilenceMilliseconds(_ events: [TelemetryEvent]) -> Int? {
        events.lazy.compactMap(\.metrics.endpointSilenceMilliseconds).first
    }

    private static func collectEndpointShadowMetrics(
        _ events: [TelemetryEvent],
        into samples: inout [LatencyMetricName: [Double]]
    ) {
        for event in events where event.name == .shadowEndpointFinalComparison {
            if let duration = event.metrics.durationMilliseconds {
                samples[.endpointCandidateToFinal, default: []].append(duration)
            }
            guard event.metrics.shadowCandidatePresent == true else { continue }
            if let match = event.metrics.shadowCandidateMatchRatio {
                samples[.endpointCandidateMatchRatio, default: []].append(match)
            }
            if let coverage = event.metrics.shadowFinalCoverageRatio {
                samples[.endpointFinalCoverageRatio, default: []].append(coverage)
            }
        }
    }

    private static func collectEndpointFinalizationMetrics(
        _ events: [TelemetryEvent],
        into samples: inout [LatencyMetricName: [Double]]
    ) {
        for event in events
        where event.name == .shadowEndpointFinalizeCompleted
            || event.name == .shadowEndpointFinalizeFailed
        {
            if let duration = event.metrics.durationMilliseconds {
                samples[.endpointFinalizeDuration, default: []].append(duration)
            }
        }
    }

    private static func collectSemanticEndpointMetrics(
        _ events: [TelemetryEvent],
        into samples: inout [LatencyMetricName: [Double]]
    ) {
        for event in events
        where event.name == .semanticEndpointCompleted || event.name == .semanticEndpointFailed {
            if let duration = event.metrics.durationMilliseconds {
                samples[.semanticInferenceDuration, default: []].append(duration)
            }
        }
    }

    private static func collectSourceTimings(
        _ events: [TelemetryEvent],
        into samples: inout [LatencyMetricName: [Double]]
    ) {
        var partialTimingUtterances = Set<UUID>()
        for event in events {
            guard let value = event.metrics.sourceLatencyMilliseconds,
                let utteranceID = event.utteranceID
            else {
                continue
            }
            if event.name == .speechEndTiming {
                samples[.audioToSpeechEndDelivery, default: []].append(value)
            } else if event.name == .asrPartialTiming,
                partialTimingUtterances.insert(utteranceID).inserted
            {
                samples[.audioToFirstPartialDelivery, default: []].append(value)
            } else if event.name == .asrFinalTiming {
                samples[.audioToFinalDelivery, default: []].append(value)
            }
        }
    }

    private static func collectRequestMetrics(
        _ events: [TelemetryEvent],
        into samples: inout [LatencyMetricName: [Double]]
    ) {
        for event in events where event.name == .requestCompleted {
            guard let server = event.metrics.serverDurationMilliseconds else { continue }
            samples[.serverElapsed, default: []].append(server)
            if let total = event.metrics.durationMilliseconds {
                samples[.requestMinusServer, default: []].append(max(0, total - server))
            }
        }
    }

    private static func collectPreflightMetrics(
        _ events: [TelemetryEvent],
        into samples: inout [LatencyMetricName: [Double]]
    ) {
        for event in events where event.name == .preflightCompleted {
            guard let duration = event.metrics.durationMilliseconds else { continue }
            let metric: LatencyMetricName?
            switch event.stage {
            case .lifecycle:
                metric = .lifecyclePreflight
            case .speech:
                metric = .speechPreflight
            case .irodori:
                metric = .irodoriPreflight
            case .coreAudio:
                metric = .coreAudioPreflight
            default:
                metric = nil
            }
            if let metric {
                samples[metric, default: []].append(duration)
            }
        }
    }

    private static func collectTimelineMetrics(
        _ timelines: [UUID: [TelemetryEventName: UInt64]],
        into samples: inout [LatencyMetricName: [Double]]
    ) {
        for timeline in timelines.values {
            collect(.asrFinalToRequest, .asrFinal, .requestStarted, from: timeline, into: &samples)
            collect(
                .requestToHandshake, .requestStarted, .streamHandshake, from: timeline,
                into: &samples)
            collect(
                .requestToFirstAudio,
                .requestStarted,
                .firstAudioPayload,
                from: timeline,
                into: &samples
            )
            collect(
                .requestToComplete,
                .requestStarted,
                .requestCompleted,
                from: timeline,
                into: &samples
            )
            collect(
                .playbackQueueWait,
                .playbackEnqueued,
                .playbackStarted,
                from: timeline,
                into: &samples
            )
            collect(
                .speechEndToPlayback,
                .speechEnded,
                .playbackStarted,
                from: timeline,
                into: &samples
            )
            collect(
                .speechStartToPlayback,
                .speechStarted,
                .playbackStarted,
                from: timeline,
                into: &samples
            )
            collect(
                .synthesisCompleteToPlayback,
                .requestCompleted,
                .playbackStarted,
                from: timeline,
                into: &samples
            )
        }
    }

    private static func collectAudioEndToPlayback(
        _ events: [TelemetryEvent],
        timelines: [UUID: [TelemetryEventName: UInt64]],
        into samples: inout [LatencyMetricName: [Double]]
    ) {
        for event in events where event.name == .asrFinalTiming {
            guard let utteranceID = event.utteranceID,
                let sourceLatency = event.metrics.sourceLatencyMilliseconds,
                let final = timelines[utteranceID]?[.asrFinal],
                let playback = timelines[utteranceID]?[.playbackStarted],
                playback >= final
            else {
                continue
            }
            let afterFinal = Double(playback - final) / 1_000_000
            samples[.audioEndToPlayback, default: []].append(sourceLatency + afterFinal)
        }
    }

    private static func collectRealTimeFactors(
        _ events: [TelemetryEvent],
        into samples: inout [LatencyMetricName: [Double]]
    ) {
        for event in events where event.name == .playbackEnqueued {
            guard let utteranceID = event.utteranceID,
                let request = events.first(where: {
                    $0.utteranceID == utteranceID && $0.name == .requestCompleted
                }),
                let synthesisMilliseconds = request.metrics.durationMilliseconds,
                let audioMilliseconds = event.metrics.audioDurationMilliseconds,
                audioMilliseconds > 0
            else { continue }
            samples[.realTimeFactor, default: []].append(
                synthesisMilliseconds / audioMilliseconds)
        }
    }

    private static func collectPlaybackGaps(
        _ events: [TelemetryEvent],
        into samples: inout [LatencyMetricName: [Double]]
    ) {
        let playbackEvents =
            events
            .filter { $0.name == .playbackStarted || $0.name == .playbackCompleted }
            .sorted { $0.timestampNanoseconds < $1.timestampNanoseconds }
        var previousCompletion: UInt64?
        for event in playbackEvents {
            if event.name == .playbackCompleted {
                previousCompletion = event.timestampNanoseconds
            } else if let previousCompletion, event.timestampNanoseconds >= previousCompletion {
                samples[.playbackGap, default: []].append(
                    Double(event.timestampNanoseconds - previousCompletion) / 1_000_000)
            }
        }
    }

    private static func collectShadowMetrics(
        _ events: [TelemetryEvent],
        timelines: [UUID: [TelemetryEventName: UInt64]],
        into samples: inout [LatencyMetricName: [Double]]
    ) {
        for timeline in timelines.values {
            collect(
                .speechStartToShadowCandidate,
                .speechStarted,
                .shadowPrefixCandidate,
                from: timeline,
                into: &samples
            )
            collect(
                .shadowCandidateToFinal,
                .shadowPrefixCandidate,
                .shadowFinalComparison,
                from: timeline,
                into: &samples
            )
        }
        for event in events where event.name == .shadowFinalComparison {
            guard event.metrics.shadowCandidatePresent == true else { continue }
            if let match = event.metrics.shadowCandidateMatchRatio {
                samples[.shadowCandidateMatchRatio, default: []].append(match)
            }
            if let coverage = event.metrics.shadowFinalCoverageRatio {
                samples[.shadowFinalCoverageRatio, default: []].append(coverage)
            }
        }
    }

    private static func collectShadowSynthesisMetrics(
        _ events: [TelemetryEvent],
        timelines: [UUID: [TelemetryEventName: UInt64]],
        into samples: inout [LatencyMetricName: [Double]]
    ) {
        for timeline in timelines.values {
            collect(
                .shadowSynthesisRequestToHandshake,
                .shadowSynthesisStarted,
                .shadowSynthesisHandshake,
                from: timeline,
                into: &samples
            )
            collect(
                .shadowSynthesisRequestToFirstAudio,
                .shadowSynthesisStarted,
                .shadowSynthesisFirstAudio,
                from: timeline,
                into: &samples
            )
            collect(
                .shadowSynthesisRequestToComplete,
                .shadowSynthesisStarted,
                .shadowSynthesisCompleted,
                from: timeline,
                into: &samples
            )
        }
        for event in events where event.name == .shadowSynthesisCompleted {
            guard let server = event.metrics.serverDurationMilliseconds else { continue }
            samples[.shadowSynthesisServerElapsed, default: []].append(server)
            if let total = event.metrics.durationMilliseconds {
                samples[.shadowSynthesisRequestMinusServer, default: []].append(
                    max(0, total - server))
            }
        }
        for event in events where event.name == .shadowSynthesisFinalComparison {
            if let match = event.metrics.shadowCandidateMatchRatio {
                samples[.shadowSynthesisCandidateMatchRatio, default: []].append(match)
            }
            if let coverage = event.metrics.shadowFinalCoverageRatio {
                samples[.shadowSynthesisFinalCoverageRatio, default: []].append(coverage)
            }
        }
    }

    private static func collect(
        _ metric: LatencyMetricName,
        _ startName: TelemetryEventName,
        _ endName: TelemetryEventName,
        from timeline: [TelemetryEventName: UInt64],
        into samples: inout [LatencyMetricName: [Double]]
    ) {
        guard let start = timeline[startName], let end = timeline[endName], end >= start else {
            return
        }
        samples[metric, default: []].append(Double(end - start) / 1_000_000)
    }
}

public enum TelemetryEventReader {
    public static func load(from directory: URL) throws -> [TelemetryEvent] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("events") && $0.pathExtension == "jsonl" }
        var events = [TelemetryEvent]()
        for file in files.sorted(by: isEarlierTelemetryFile) {
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                events.append(try JSONDecoder.telemetry.decode(TelemetryEvent.self, from: line))
            }
        }
        return events
    }

    private static func isEarlierTelemetryFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.lastPathComponent == "events.jsonl" { return false }
        if rhs.lastPathComponent == "events.jsonl" { return true }
        let lhsIndex = archiveIndex(of: lhs)
        let rhsIndex = archiveIndex(of: rhs)
        if let lhsIndex, let rhsIndex, lhsIndex != rhsIndex {
            return lhsIndex > rhsIndex
        }
        return lhs.lastPathComponent < rhs.lastPathComponent
    }

    private static func archiveIndex(of file: URL) -> Int? {
        let stem = file.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("events.") else { return nil }
        return Int(stem.dropFirst("events.".count))
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue _: Int) {
        return nil
    }
}
