// LLMProvider.swift
// OpenSuperMLX

import Foundation

protocol LLMProvider: Sendable {
    var displayName: String { get }
    var isConfigured: Bool { get }
    func correctTranscription(_ text: String, systemPrompt: String) async throws -> String
}

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
}
