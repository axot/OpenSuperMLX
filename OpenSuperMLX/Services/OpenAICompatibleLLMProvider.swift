// OpenAICompatibleLLMProvider.swift
// OpenSuperMLX

import Foundation
import os.log

private let logger = Logger(subsystem: "OpenSuperMLX", category: "OpenAICompatibleLLMProvider")

final class OpenAICompatibleLLMProvider: LLMProvider, @unchecked Sendable {

    private var llmURLSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    let displayName = "OpenAI Compatible"

    var isConfigured: Bool {
        let prefs = AppPreferences.shared
        guard let url = URL(string: prefs.openAIBaseURL), url.scheme != nil else { return false }
        return !prefs.openAIModel.isEmpty
    }

    func correctTranscription(_ text: String, systemPrompt: String) async throws -> String {
        let prefs = AppPreferences.shared
        let apiProtocol = OpenAIAPIProtocol(rawValue: prefs.openAIAPIProtocol) ?? .chatCompletions

        var baseURLString = prefs.openAIBaseURL
        while baseURLString.hasSuffix("/") {
            baseURLString.removeLast()
        }

        guard let baseURL = URL(string: baseURLString) else {
            throw LLMProviderError.notConfigured(provider: displayName)
        }

        let url = baseURL.appendingPathComponent(apiProtocol.endpointPath)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if !prefs.openAIAPIKey.isEmpty {
            request.setValue("Bearer \(prefs.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        }

        for (key, value) in parseCustomHeaders(prefs.openAICustomHeaders) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try makeRequestBody(
            model: prefs.openAIModel,
            text: text,
            systemPrompt: systemPrompt,
            apiProtocol: apiProtocol
        )

        let (data, response) = try await sendWithRetry(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.networkError(underlying: URLError(.badServerResponse))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorResponse = try? JSONDecoder.snakeCase.decode(
                APIErrorResponse.self, from: data
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

        return try parseResponseBody(data, apiProtocol: apiProtocol)
    }

    func makeRequestBody(
        model: String,
        text: String,
        systemPrompt: String,
        apiProtocol: OpenAIAPIProtocol
    ) throws -> Data {
        switch apiProtocol {
        case .chatCompletions:
            return try JSONEncoder.snakeCase.encode(
                ChatCompletionRequest(
                    model: model,
                    messages: [
                        .init(role: "system", content: systemPrompt),
                        .init(role: "user", content: text),
                    ],
                    temperature: 0.1,
                    maxTokens: 4096
                )
            )
        case .responses:
            return try JSONEncoder.snakeCase.encode(
                ResponsesAPIRequest(
                    model: model,
                    input: [
                        .init(role: "system", content: systemPrompt),
                        .init(role: "user", content: text),
                    ],
                    temperature: 0.1,
                    maxOutputTokens: 4096
                )
            )
        }
    }

    func parseResponseBody(_ data: Data, apiProtocol: OpenAIAPIProtocol) throws -> String {
        switch apiProtocol {
        case .chatCompletions:
            let completion = try JSONDecoder.snakeCase.decode(ChatCompletionResponse.self, from: data)
            guard let content = completion.choices.first?.message.content, !content.isEmpty else {
                throw LLMProviderError.emptyResponse
            }
            return content
        case .responses:
            let apiResponse = try JSONDecoder.snakeCase.decode(ResponsesAPIResponse.self, from: data)
            guard let text = apiResponse.outputText else {
                throw LLMProviderError.emptyResponse
            }
            return text
        }
    }

    // MARK: - Private

    private func sendWithRetry(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error?

        for attempt in 1...3 {
            try Task.checkCancellation()
            do {
                return try await sendWithConnectTimeout(request, timeout: 2.0)
            } catch {
                let isConnectionError = (error as? URLError).map {
                    $0.code == .timedOut || $0.code == .networkConnectionLost || $0.code == .cannotConnectToHost
                } ?? false

                guard isConnectionError else { throw error }

                lastError = error
                logger.warning("Connection attempt \(attempt, privacy: .public)/3 failed: \(error.localizedDescription, privacy: .public)")
                if attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }

        try Task.checkCancellation()

        logger.warning("All fast retries failed (\(lastError?.localizedDescription ?? "unknown", privacy: .public)), resetting session")
        llmURLSession.invalidateAndCancel()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForResource = 60
        llmURLSession = URLSession(configuration: config)

        return try await llmURLSession.data(for: request)
    }

    private func sendWithConnectTimeout(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        var timedRequest = request
        timedRequest.timeoutInterval = timeout
        return try await llmURLSession.data(for: timedRequest)
    }

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

private struct ResponsesAPIRequest: Encodable {
    let model: String
    let input: [Message]
    let temperature: Double?
    let maxOutputTokens: Int?
    let stream: Bool = false

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ResponsesAPIResponse: Decodable {
    let output: [OutputItem]

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

private struct APIErrorResponse: Decodable {
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
