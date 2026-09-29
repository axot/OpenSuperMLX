// OpenAICompatibleLLMProvider.swift
// OpenSuperMLX

import Foundation
import os.log

private let logger = Logger(subsystem: "OpenSuperMLX", category: "OpenAICompatibleLLMProvider")

final class OpenAICompatibleLLMProvider: LLMProvider, @unchecked Sendable {

    // Non-streaming requests send nothing until the whole output is ready, so the transport must
    // outlast the longest correction; `LLMCorrectionService` enforces the real time limit.
    static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 900
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    private static let thinkingOverrideKeys = ["reasoning_effort", "reasoning", "thinking", "output_config"]

    private let session: URLSession
    private let variantCache: LLMThinkingVariantCache
    // Learned once per provider instance (one correction run) so later chunks skip the rejected field.
    private var prefersMaxCompletionTokens = false

    let displayName = "OpenAI Compatible"

    init(session: URLSession = OpenAICompatibleLLMProvider.sharedSession, variantCache: LLMThinkingVariantCache = .shared) {
        self.session = session
        self.variantCache = variantCache
    }

    var isConfigured: Bool {
        let prefs = AppPreferences.shared
        guard let url = URL(string: prefs.openAIBaseURL), url.scheme != nil else { return false }
        return !prefs.openAIModel.isEmpty
    }

    var requestOptions: LLMRequestOptions {
        AppPreferences.shared.llmRequestOptions(for: .openai)
    }

    func correctTranscription(_ text: String, systemPrompt: String) async throws -> String {
        let prefs = AppPreferences.shared
        let apiProtocol = Self.resolvedAPIProtocol(rawValue: prefs.openAIAPIProtocol)

        guard let url = makeRequestURL(baseURLString: prefs.openAIBaseURL, apiProtocol: apiProtocol) else {
            throw LLMProviderError.notConfigured(provider: displayName)
        }

        let options = requestOptions
        let extraBody = Self.parseJSONObject(prefs.openAIExtraBody)
        let headers = Self.parseJSONObject(prefs.openAICustomHeaders) as? [String: String] ?? [:]
        let overridesThinking = extraBody.keys.contains { Self.thinkingOverrideKeys.contains($0) }
        let variants = overridesThinking ? [.primary] : Self.thinkingVariants(for: apiProtocol, options: options)
        let cacheKey = "\(prefs.openAIBaseURL)|\(apiProtocol.rawValue)|\(prefs.openAIModel)|\(options.thinkingEnabled)"

        let data = try await variantCache.firstAccepted(key: cacheKey, variants: variants) { variant in
            while true {
                let body = try makeRequestBody(
                    model: prefs.openAIModel,
                    text: text,
                    systemPrompt: systemPrompt,
                    apiProtocol: apiProtocol,
                    options: options,
                    extraBody: extraBody,
                    thinking: variant,
                    useMaxCompletionTokens: prefersMaxCompletionTokens
                )
                let request = makeURLRequest(
                    url: url, apiProtocol: apiProtocol, apiKey: prefs.openAIAPIKey, customHeaders: headers, body: body
                )
                let (data, response) = try await send(request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw LLMProviderError.networkError(underlying: URLError(.badServerResponse))
                }
                if (200...299).contains(httpResponse.statusCode) {
                    return data
                }

                let message = Self.errorMessage(from: data)
                if apiProtocol == .chatCompletions, !prefersMaxCompletionTokens, httpResponse.statusCode == 400,
                   message.contains("max_completion_tokens") {
                    prefersMaxCompletionTokens = true
                    continue
                }
                let error = LLMProviderError.fromHTTP(statusCode: httpResponse.statusCode, message: message, provider: displayName)
                if error.rejectsThinkingParameters {
                    logger.warning("Server rejected thinking parameters: \(message, privacy: .public)")
                }
                throw error
            }
        }
        return try parseResponseBody(data, apiProtocol: apiProtocol)
    }

    static func resolvedAPIProtocol(rawValue: String) -> OpenAIAPIProtocol {
        OpenAIAPIProtocol(rawValue: rawValue) ?? .chatCompletions
    }

    static func thinkingVariants(for apiProtocol: OpenAIAPIProtocol, options: LLMRequestOptions) -> [LLMThinkingVariant] {
        if apiProtocol == .anthropicMessages, options.thinkingEnabled {
            return [.primary, .legacyBudget, .omitted]
        }
        return [.primary, .omitted]
    }

    // A connection that dies right away is usually a stale pooled socket (e.g. after sleep); one that
    // dies after the server has been generating would be re-billed in full, so it isn't replayed.
    static func isFastRetryable(_ error: URLError, after elapsed: Duration) -> Bool {
        (error.code == .networkConnectionLost || error.code == .cannotConnectToHost) && elapsed < .seconds(2)
    }

    static func parseJSONObject(_ json: String) -> [String: Any] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return object
    }

    func makeRequestURL(baseURLString: String, apiProtocol: OpenAIAPIProtocol) -> URL? {
        var trimmed = baseURLString
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let baseURL = URL(string: trimmed) else { return nil }
        return baseURL.appendingPathComponent(apiProtocol.endpointPath)
    }

    func makeURLRequest(
        url: URL,
        apiProtocol: OpenAIAPIProtocol,
        apiKey: String,
        customHeaders: [String: String],
        body: Data
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if apiProtocol == .anthropicMessages {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
        } else if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        return request
    }

    func makeRequestBody(
        model: String,
        text: String,
        systemPrompt: String,
        apiProtocol: OpenAIAPIProtocol,
        options: LLMRequestOptions,
        extraBody: [String: Any] = [:],
        thinking: LLMThinkingVariant = .primary,
        useMaxCompletionTokens: Bool = false
    ) throws -> Data {
        let outputLimit = options.outputTokenLimit(systemPrompt: systemPrompt, text: text)
        let effort = options.thinkingEnabled ? options.thinkingEffort.rawValue : "none"
        var body: [String: Any] = ["model": model, "stream": false]

        switch apiProtocol {
        case .chatCompletions:
            body["messages"] = [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ]
            body[useMaxCompletionTokens ? "max_completion_tokens" : "max_tokens"] = outputLimit
            if thinking == .primary {
                body["reasoning_effort"] = effort
            }
        case .responses:
            body["input"] = [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ]
            body["max_output_tokens"] = outputLimit
            if thinking == .primary {
                body["reasoning"] = ["effort": effort]
            }
        case .anthropicMessages:
            body["system"] = systemPrompt
            body["messages"] = [["role": "user", "content": text]]
            body["max_tokens"] = outputLimit
            body.merge(LLMThinkingVariant.anthropicFields(options: options, variant: thinking, outputLimit: outputLimit)) { $1 }
        }

        body.merge(extraBody) { $1 }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    func parseResponseBody(_ data: Data, apiProtocol: OpenAIAPIProtocol) throws -> String {
        let text: String?
        switch apiProtocol {
        case .chatCompletions:
            let completion = try JSONDecoder.snakeCase.decode(ChatCompletionResponse.self, from: data)
            let choice = completion.choices.first
            switch choice?.finishReason {
            case "length": throw LLMProviderError.outputTruncated(provider: displayName)
            case "content_filter": throw LLMProviderError.outputRejected(provider: displayName, reason: "content_filter")
            default: text = choice?.message.content
            }
        case .responses:
            let apiResponse = try JSONDecoder.snakeCase.decode(ResponsesAPIResponse.self, from: data)
            if apiResponse.status == "incomplete" {
                let reason = apiResponse.incompleteDetails?.reason ?? "incomplete"
                if reason == "content_filter" {
                    throw LLMProviderError.outputRejected(provider: displayName, reason: reason)
                }
                throw LLMProviderError.outputTruncated(provider: displayName)
            }
            text = apiResponse.outputText
        case .anthropicMessages:
            let message = try JSONDecoder.snakeCase.decode(AnthropicMessageResponse.self, from: data)
            switch message.stopReason {
            case "max_tokens", "model_context_window_exceeded":
                throw LLMProviderError.outputTruncated(provider: displayName)
            case "refusal":
                throw LLMProviderError.outputRejected(provider: displayName, reason: "refusal")
            default:
                text = message.content.filter { $0.type == "text" }.compactMap(\.text).joined()
            }
        }

        let result = Self.strippingLeadingThinkTags(text ?? "")
        guard !result.isEmpty else { throw LLMProviderError.emptyResponse }
        return result
    }

    // MARK: - Private

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 1
        while true {
            if Task.isCancelled { throw LLMProviderError.cancelled }
            let start = ContinuousClock.now
            do {
                return try await session.data(for: request)
            } catch let error as URLError {
                if error.code == .cancelled { throw LLMProviderError.cancelled }
                guard Self.isFastRetryable(error, after: ContinuousClock.now - start), attempt < 3 else {
                    throw LLMProviderError.networkError(underlying: error)
                }
                logger.warning("Connection attempt \(attempt, privacy: .public)/3 failed: \(error.localizedDescription, privacy: .public)")
                attempt += 1
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private static func errorMessage(from data: Data) -> String {
        if let errorResponse = try? JSONDecoder.snakeCase.decode(APIErrorResponse.self, from: data) {
            return errorResponse.error.message
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = (object["message"] ?? object["detail"]) as? String {
            return message
        }
        return String(data: data.prefix(1000), encoding: .utf8) ?? "Unknown error"
    }

    // Some local servers put the model's reasoning inline as `<think>…</think>` before the answer.
    private static func strippingLeadingThinkTags(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("<think>"), let end = result.range(of: "</think>") {
            result = String(result[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}

// MARK: - Response Types

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?
    }

    struct Message: Decodable {
        let content: String?
    }
}

private struct ResponsesAPIResponse: Decodable {
    let status: String?
    let incompleteDetails: IncompleteDetails?
    let output: [OutputItem]

    struct IncompleteDetails: Decodable {
        let reason: String?
    }

    struct OutputItem: Decodable {
        let type: String?
        let content: [ContentItem]?

        struct ContentItem: Decodable {
            let type: String?
            let text: String?
        }
    }

    var outputText: String? {
        var texts: [String] = []
        for item in output where item.type == "message" {
            for contentItem in item.content ?? [] where contentItem.type == "output_text" {
                if let text = contentItem.text {
                    texts.append(text)
                }
            }
        }
        let joined = texts.joined()
        return joined.isEmpty ? nil : joined
    }
}

private struct AnthropicMessageResponse: Decodable {
    let content: [ContentBlock]
    let stopReason: String?

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
}

private struct APIErrorResponse: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let message: String
    }
}

// MARK: - JSON Coding Helpers

private extension JSONDecoder {
    static let snakeCase: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
