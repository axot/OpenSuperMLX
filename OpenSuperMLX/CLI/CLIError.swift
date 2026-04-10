// CLIError.swift
// OpenSuperMLX

import Foundation

enum CLIError: String, Error, CustomStringConvertible {
    case modelNotFound = "model_not_found"
    case modelNotCached = "model_not_cached"
    case modelLoadFailed = "model_load_failed"
    case audioFileNotFound = "audio_file_not_found"
    case audioFormatUnsupported = "audio_format_unsupported"
    case transcriptionFailed = "transcription_failed"
    case streamTimeout = "stream_timeout"
    case llmCorrectionFailed = "llm_correction_failed"
    case databaseError = "database_error"
    case audioFileMissing = "audio_file_missing"
    case invalidConfigKey = "invalid_config_key"
    case invalidConfigValue = "invalid_config_value"

    var description: String {
        switch self {
        case .modelNotFound: return "Specified model not found in catalog"
        case .modelNotCached: return "Model not downloaded locally; run 'model download' first"
        case .modelLoadFailed: return "Failed to load model"
        case .audioFileNotFound: return "Audio file not found"
        case .audioFormatUnsupported: return "Audio format not supported"
        case .transcriptionFailed: return "Transcription failed"
        case .streamTimeout: return "Stream simulation timed out"
        case .llmCorrectionFailed: return "LLM correction failed"
        case .databaseError: return "Database operation failed"
        case .audioFileMissing: return "Recording audio file missing from disk"
        case .invalidConfigKey: return "Unknown configuration key"
        case .invalidConfigValue: return "Invalid value for configuration key"
        }
    }

    var exitCode: Int32 { 1 }
}
