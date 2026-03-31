// LLMProvider.swift
// OpenSuperMLX

import Foundation

// MARK: - Protocol

protocol LLMProvider: Sendable {
    var displayName: String { get }
    var isConfigured: Bool { get }
    func correctTranscription(_ text: String, systemPrompt: String) async throws -> String
}

// MARK: - Provider Type

enum LLMProviderType: String, CaseIterable {
    case bedrock
    case openai

    var displayName: String {
        switch self {
        case .bedrock: return "AWS Bedrock"
        case .openai: return "OpenAI Compatible"
        }
    }
}

// MARK: - Provider Error

enum LLMProviderError: LocalizedError {
    case notConfigured(provider: String)
    case emptyResponse
    case timeout(seconds: Int)
    case cancelled
    case networkError(underlying: Error)
    case httpError(statusCode: Int, message: String)
    case apiError(provider: String, message: String, code: String?)
    case authenticationFailed(provider: String, detail: String)
    case rateLimited(provider: String, retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let provider):
            return "\(provider) is not configured."
        case .emptyResponse:
            return "LLM returned an empty response."
        case .timeout(let seconds):
            return "LLM request timed out after \(seconds) seconds."
        case .cancelled:
            return "LLM request was cancelled."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .httpError(let code, let message):
            return "HTTP \(code): \(message)"
        case .apiError(_, let message, _):
            return message
        case .authenticationFailed(let provider, let detail):
            return "\(provider) authentication failed: \(detail)"
        case .rateLimited(let provider, _):
            return "\(provider) rate limit exceeded. Try again later."
        }
    }

    var userFacingMessage: String {
        switch self {
        case .authenticationFailed:
            return "Invalid API key. Check Settings → LLM."
        case .notConfigured:
            return "LLM is not configured. Check Settings → LLM."
        case .emptyResponse:
            return "LLM returned an empty result. Try a different model or prompt."
        case .rateLimited:
            return "Rate limit reached. Please wait and try again."
        case .timeout:
            return "LLM request timed out."
        case .networkError:
            return "Cannot connect to LLM server. Check the API endpoint."
        case .cancelled:
            return "LLM request was cancelled."
        case .apiError(_, let message, _):
            let lower = message.lowercased()
            if lower.contains("not exist") || lower.contains("not found") || lower.contains("not_found") {
                return "Model not found. Check the model name in Settings → LLM."
            }
            return "LLM correction failed. Check Settings → LLM."
        case .httpError(let statusCode, let message):
            if statusCode == 401 || statusCode == 403 {
                return "Invalid API key. Check Settings → LLM."
            }
            if statusCode == 429 {
                return "Rate limit reached. Please wait and try again."
            }
            if statusCode == 404 {
                return "Model not found. Check the model name in Settings → LLM."
            }
            let lower = message.lowercased()
            if lower.contains("not exist") || lower.contains("not found") || lower.contains("not_found") {
                return "Model not found. Check the model name in Settings → LLM."
            }
            return "LLM correction failed. Check Settings → LLM."
        }
    }

    var providerName: String? {
        switch self {
        case .notConfigured(let provider), .apiError(let provider, _, _),
             .authenticationFailed(let provider, _), .rateLimited(let provider, _):
            return provider
        default:
            return nil
        }
    }
}
