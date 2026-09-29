// LLMProvider.swift
// OpenSuperMLX

import Foundation

// MARK: - Protocol

protocol LLMProvider: Sendable {
    var displayName: String { get }
    var isConfigured: Bool { get }
    /// Context, output and thinking settings the provider will apply to its next request.
    var requestOptions: LLMRequestOptions { get }
    func correctTranscription(_ text: String, systemPrompt: String) async throws -> String
}

// MARK: - Request Options

enum LLMThinkingEffort: String, CaseIterable, Sendable {
    case low
    case medium
    case high

    var displayName: String { rawValue.capitalized }

    var budgetTokens: Int {
        switch self {
        case .low: return 2048
        case .medium: return 8192
        case .high: return 16_384
        }
    }
}

struct LLMRequestOptions: Equatable, Sendable {
    static let tokenRange = 512...2_000_000

    var contextTokens: Int
    var maxOutputTokens: Int
    var thinkingEnabled: Bool
    var thinkingEffort: LLMThinkingEffort

    var thinkingBudgetTokens: Int { min(thinkingEffort.budgetTokens, maxOutputTokens / 2) }
    var reservedThinkingTokens: Int { thinkingEnabled ? thinkingBudgetTokens : 0 }

    static func clampedTokens(_ value: Int) -> Int {
        min(max(value, tokenRange.lowerBound), tokenRange.upperBound)
    }

    // Servers reject requests whose prompt plus `max_tokens` exceeds the context window.
    func outputTokenLimit(systemPrompt: String, text: String) -> Int {
        let inputTokens = TranscriptChunker.estimatedTokens(systemPrompt) + TranscriptChunker.estimatedTokens(text)
        return max(256, min(maxOutputTokens, contextTokens - inputTokens - 512))
    }
}

// MARK: - Thinking Variants

// Thinking parameter shapes tried in order until the server accepts one.
enum LLMThinkingVariant: Sendable {
    case primary
    case legacyBudget
    case omitted

    // Anthropic Messages fields (also used inside Bedrock `additionalModelRequestFields`).
    static func anthropicFields(options: LLMRequestOptions, variant: LLMThinkingVariant, outputLimit: Int) -> [String: Any] {
        guard options.thinkingEnabled else {
            return variant == .primary ? ["thinking": ["type": "disabled"]] : [:]
        }
        switch variant {
        case .primary:
            return ["thinking": ["type": "adaptive"], "output_config": ["effort": options.thinkingEffort.rawValue]]
        case .legacyBudget:
            let budget = max(1024, options.thinkingBudgetTokens)
            return budget < outputLimit ? ["thinking": ["type": "enabled", "budget_tokens": budget]] : [:]
        case .omitted:
            return [:]
        }
    }
}

// Remembers which thinking variant each endpoint accepted, so later requests skip known rejections.
final class LLMThinkingVariantCache: @unchecked Sendable {
    static let shared = LLMThinkingVariantCache()

    private let lock = NSLock()
    private var acceptedIndex: [String: Int] = [:]

    func firstAccepted<T>(
        key: String,
        variants: [LLMThinkingVariant],
        attempt: (LLMThinkingVariant) async throws -> T
    ) async throws -> T {
        var index = min(lock.withLock { acceptedIndex[key] ?? 0 }, variants.count - 1)
        while true {
            do {
                let result = try await attempt(variants[index])
                lock.withLock { acceptedIndex[key] = index }
                return result
            } catch let error as LLMProviderError where error.rejectsThinkingParameters && index + 1 < variants.count {
                index += 1
            }
        }
    }
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

// MARK: - OpenAI API Protocol

enum OpenAIAPIProtocol: String, CaseIterable {
    case chatCompletions = "chat_completions"
    case responses
    case anthropicMessages = "anthropic_messages"

    var displayName: String {
        switch self {
        case .chatCompletions: return "Chat Completions"
        case .responses: return "Responses"
        case .anthropicMessages: return "Anthropic Messages"
        }
    }

    var endpointPath: String {
        switch self {
        case .chatCompletions: return "chat/completions"
        case .responses: return "responses"
        case .anthropicMessages: return "messages"
        }
    }
}

// MARK: - Failure Kind

enum LLMFailureKind: Equatable, Sendable {
    // Network, timeout, throttling or server errors: retrying later may succeed.
    case transient
    // Configuration or credential problems: every request will fail the same way.
    case permanent
    // Something about this particular request failed (size, truncation, bad request, empty output).
    case perRequest
    case cancelled
}

// MARK: - Provider Error

enum LLMProviderError: LocalizedError {
    case notConfigured(provider: String)
    case emptyResponse
    case timeout(seconds: Int)
    case cancelled
    case networkError(underlying: Error)
    case httpError(statusCode: Int, message: String)
    case authenticationFailed(provider: String, detail: String)
    case rateLimited(provider: String, retryAfter: TimeInterval?)
    // The server rejected the request's token limits or context size rather than its content.
    case requestTooLarge(provider: String, detail: String)
    case outputTruncated(provider: String)
    case outputRejected(provider: String, reason: String)

    private static let limitKeywords = ["token", "context", "length", "maximum", "max_", "too long"]
    private static let thinkingKeywords = ["reasoning", "thinking", "effort", "adaptive", "budget"]

    // Classifies a non-2xx response once, where it enters the app.
    static func fromHTTP(statusCode: Int, message: String, provider: String) -> LLMProviderError {
        switch statusCode {
        case 401:
            return .authenticationFailed(provider: provider, detail: message)
        case 429:
            return .rateLimited(provider: provider, retryAfter: nil)
        case 400, 413, 422:
            return mentions(limitKeywords, in: message)
                ? .requestTooLarge(provider: provider, detail: message)
                : .httpError(statusCode: statusCode, message: message)
        default:
            return .httpError(statusCode: statusCode, message: message)
        }
    }

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
        case .authenticationFailed(let provider, let detail):
            return "\(provider) authentication failed: \(detail)"
        case .rateLimited(let provider, _):
            return "\(provider) rate limit exceeded. Try again later."
        case .requestTooLarge(let provider, let detail):
            return "\(provider) rejected the request size: \(detail)"
        case .outputTruncated(let provider):
            return "\(provider) stopped before finishing the output."
        case .outputRejected(let provider, let reason):
            return "\(provider) declined to return output (\(reason))."
        }
    }

    var failureKind: LLMFailureKind {
        switch self {
        case .cancelled:
            return .cancelled
        case .networkError, .timeout, .rateLimited:
            return .transient
        case .notConfigured, .authenticationFailed:
            return .permanent
        case .httpError(let statusCode, _):
            switch statusCode {
            case 408, 429, 500...599: return .transient
            case 401, 403, 404: return .permanent
            default: return .perRequest
            }
        case .emptyResponse, .requestTooLarge, .outputTruncated, .outputRejected:
            return .perRequest
        }
    }

    var rejectsThinkingParameters: Bool {
        switch self {
        case .httpError(let statusCode, let message) where statusCode == 400 || statusCode == 422:
            return Self.mentions(Self.thinkingKeywords, in: message)
        case .requestTooLarge(_, let detail):
            return Self.mentions(Self.thinkingKeywords, in: detail)
        default:
            return false
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
        case .requestTooLarge:
            return "The output limit or context size may exceed what the model supports. Adjust them in Settings → LLM."
        case .outputTruncated:
            return "LLM output was cut off. Original text kept."
        case .outputRejected:
            return "LLM declined to correct this text. Original text kept."
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
        case .notConfigured(let provider), .authenticationFailed(let provider, _),
             .rateLimited(let provider, _), .requestTooLarge(let provider, _):
            return provider
        default:
            return nil
        }
    }

    private static func mentions(_ keywords: [String], in message: String) -> Bool {
        let lower = message.lowercased()
        return keywords.contains { lower.contains($0) }
    }
}
