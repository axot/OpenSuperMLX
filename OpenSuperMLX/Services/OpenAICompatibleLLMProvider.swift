// OpenAICompatibleLLMProvider.swift
// OpenSuperMLX

import Foundation
import os.log

private let logger = Logger(subsystem: "OpenSuperMLX", category: "OpenAICompatibleLLMProvider")

final class OpenAICompatibleLLMProvider: LLMProvider, @unchecked Sendable {

    let displayName = "OpenAI Compatible"

    var isConfigured: Bool {
        let prefs = AppPreferences.shared
        guard let url = URL(string: prefs.openAIBaseURL), url.scheme != nil else { return false }
        return !prefs.openAIModel.isEmpty
    }

    func correctTranscription(_ text: String, systemPrompt: String) async throws -> String {
        let prefs = AppPreferences.shared

        var baseURLString = prefs.openAIBaseURL
        while baseURLString.hasSuffix("/") {
            baseURLString.removeLast()
        }

        guard let baseURL = URL(string: baseURLString) else {
            throw LLMProviderError.notConfigured(provider: displayName)
        }

        let url = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if !prefs.openAIAPIKey.isEmpty {
            request.setValue("Bearer \(prefs.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        }

        for (key, value) in parseCustomHeaders(prefs.openAICustomHeaders) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let body = ChatCompletionRequest(
            model: prefs.openAIModel,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: text),
            ],
            temperature: 0.1,
            maxTokens: 4096
        )

        request.httpBody = try JSONEncoder.snakeCase.encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.networkError(underlying: URLError(.badServerResponse))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorResponse = try? JSONDecoder.snakeCase.decode(
                ChatCompletionErrorResponse.self, from: data
            ) {
                let apiError = errorResponse.error
                switch httpResponse.statusCode {
                case 401:
                    throw LLMProviderError.authenticationFailed(
                        provider: displayName, detail: apiError.message
                    )
                case 429:
                    throw LLMProviderError.rateLimited(provider: displayName, retryAfter: nil)
                default:
                    throw LLMProviderError.apiError(
                        provider: displayName, message: apiError.message, code: apiError.code
                    )
                }
            }
            throw LLMProviderError.httpError(
                statusCode: httpResponse.statusCode,
                message: String(data: data, encoding: .utf8) ?? "Unknown error"
            )
        }

        let completion = try JSONDecoder.snakeCase.decode(ChatCompletionResponse.self, from: data)

        guard let content = completion.choices.first?.message.content, !content.isEmpty else {
            throw LLMProviderError.emptyResponse
        }

        return content
    }

    // MARK: - Private

    private func parseCustomHeaders(_ json: String) -> [String: String] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            return [:]
        }
        return dict
    }
}

// MARK: - Request/Response Types

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double?
    let maxTokens: Int?
    let stream: Bool = false

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}

private struct ChatCompletionErrorResponse: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let message: String
        let type: String?
        let code: String?
    }
}

// MARK: - JSON Coding Helpers

private extension JSONEncoder {
    static let snakeCase: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}

private extension JSONDecoder {
    static let snakeCase: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
