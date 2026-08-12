import Foundation

public enum PipelineStage: String, Codable, Sendable {
    case lifecycle
    case speech
    case commit
    case irodori
    case playback
    case telemetry
    case configuration
    case coreAudio = "core_audio"
}

public enum StableErrorCode: String, Codable, Sendable {
    case remoteUnavailable = "remote_unavailable"
    case runtimeGenerationMismatch = "runtime_generation_mismatch"
    case voiceNotFound = "voice_not_found"
    case backpressure
    case invalidResponse = "invalid_response"
    case responseTooLarge = "response_too_large"
    case invalidWAV = "invalid_wav"
    case outputUnavailable = "output_unavailable"
    case speechUnavailable = "speech_unavailable"
    case permissionDenied = "permission_denied"
    case telemetryUnavailable = "telemetry_unavailable"
    case invalidConfiguration = "invalid_configuration"
}
