// OpenAICompatibleLLMProviderTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class OpenAICompatibleLLMProviderTests: XCTestCase {

    private static let suiteName = "OpenAICompatibleLLMProviderTests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        AppPreferences.store = defaults
        defaults.set("https://api.openai.com/v1", forKey: "openAIBaseURL")
        defaults.set("test-key", forKey: "openAIAPIKey")
        defaults.set("gpt-4o-mini", forKey: "openAIModel")
        defaults.set("", forKey: "openAICustomHeaders")
        defaults.set("chat_completions", forKey: "openAIAPIProtocol")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: Self.suiteName)
        AppPreferences.store = .standard
        defaults = nil
        try await super.tearDown()
    }

    // MARK: - Display Name

    func testDisplayName_ReturnsOpenAICompatible() {
        let provider = OpenAICompatibleLLMProvider()
        XCTAssertEqual(provider.displayName, "OpenAI Compatible")
    }

    // MARK: - isConfigured

    func testIsConfigured_ValidBaseURLAndModel_ReturnsTrue() {
        let provider = OpenAICompatibleLLMProvider()
        XCTAssertTrue(provider.isConfigured)
    }

    func testIsConfigured_EmptyBaseURL_ReturnsFalse() {
        defaults.set("", forKey: "openAIBaseURL")
        let provider = OpenAICompatibleLLMProvider()
        XCTAssertFalse(provider.isConfigured)
    }

    func testIsConfigured_InvalidBaseURL_ReturnsFalse() {
        defaults.set("not a url", forKey: "openAIBaseURL")
        let provider = OpenAICompatibleLLMProvider()
        XCTAssertFalse(provider.isConfigured)
    }

    func testIsConfigured_EmptyModel_ReturnsFalse() {
        defaults.set("", forKey: "openAIModel")
        let provider = OpenAICompatibleLLMProvider()
        XCTAssertFalse(provider.isConfigured)
    }

    func testIsConfigured_NoAPIKey_StillReturnsTrue() {
        defaults.set("", forKey: "openAIAPIKey")
        let provider = OpenAICompatibleLLMProvider()
        XCTAssertTrue(provider.isConfigured)
    }

    // MARK: - Request URL

    func testMakeRequestURL_ChatCompletionsProtocol_AppendsChatCompletionsPath() throws {
        let provider = OpenAICompatibleLLMProvider()
        let url = try XCTUnwrap(
            provider.makeRequestURL(
                baseURLString: "https://api.openai.com/v1",
                apiProtocol: .chatCompletions
            )
        )
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testMakeRequestURL_ResponsesProtocol_TrimsTrailingSlashAndAppendsResponsesPath() throws {
        let provider = OpenAICompatibleLLMProvider()
        let url = try XCTUnwrap(
            provider.makeRequestURL(
                baseURLString: "http://localhost:1234/v1/",
                apiProtocol: .responses
            )
        )
        XCTAssertEqual(url.absoluteString, "http://localhost:1234/v1/responses")
    }

    func testMakeRequestURL_EmptyBaseURL_ReturnsNil() {
        let provider = OpenAICompatibleLLMProvider()
        XCTAssertNil(
            provider.makeRequestURL(
                baseURLString: "",
                apiProtocol: .responses
            )
        )
    }

    func testResolvedAPIProtocol_UnknownStoredValue_FallsBackToChatCompletions() {
        XCTAssertEqual(OpenAICompatibleLLMProvider.resolvedAPIProtocol(rawValue: "bogus"), .chatCompletions)
        XCTAssertEqual(OpenAICompatibleLLMProvider.resolvedAPIProtocol(rawValue: ""), .chatCompletions)
    }

    // MARK: - Request Body

    func testMakeRequestBody_ChatCompletions_EncodesMessagesArray() throws {
        let provider = OpenAICompatibleLLMProvider()
        let data = try provider.makeRequestBody(
            model: "gpt-4o-mini",
            text: " Corect text ",
            systemPrompt: "Fix typos",
            apiProtocol: .chatCompletions,
            options: makeOptions(maxOutputTokens: 4096, thinkingEnabled: false)
        )

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertNil(body["input"])

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "Fix typos")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, " Corect text ")
    }

    func testMakeRequestBody_Responses_EncodesInputArrayAndMaxOutputTokens() throws {
        let provider = OpenAICompatibleLLMProvider()
        let data = try provider.makeRequestBody(
            model: "gpt-4o-mini",
            text: " Corect text ",
            systemPrompt: "Fix typos",
            apiProtocol: .responses,
            options: makeOptions(maxOutputTokens: 4096, thinkingEnabled: false)
        )

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 4096)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertNil(body["messages"])
        XCTAssertNil(body["max_tokens"])

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input[0]["role"] as? String, "system")
        XCTAssertEqual(input[0]["content"] as? String, "Fix typos")
        XCTAssertEqual(input[1]["role"] as? String, "user")
        XCTAssertEqual(input[1]["content"] as? String, " Corect text ")
    }

    func testMakeRequestBody_OmitsTemperatureKey() throws {
        let provider = OpenAICompatibleLLMProvider()

        for apiProtocol in OpenAIAPIProtocol.allCases {
            let data = try provider.makeRequestBody(
                model: "gpt-4o-mini",
                text: "Helo wrold",
                systemPrompt: "Fix typos",
                apiProtocol: apiProtocol,
                options: makeOptions()
            )
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(
                body["temperature"],
                "Reasoning models reject requests that set temperature (\(apiProtocol))"
            )
        }
    }

    // MARK: - Response Parsing

    func testParseResponseBody_ChatCompletions_ReturnsFirstChoiceContent() throws {
        let json = """
        {"choices":[{"message":{"role":"assistant","content":"Fixed text."}}]}
        """
        let provider = OpenAICompatibleLLMProvider()
        let result = try provider.parseResponseBody(Data(json.utf8), apiProtocol: .chatCompletions)
        XCTAssertEqual(result, "Fixed text.")
    }

    func testParseResponseBody_Responses_SkipsNonMessageItemsAndJoinsOutputText() throws {
        let json = """
        {"id":"resp_1","status":"completed","output":[
            {"type":"reasoning","id":"rs_1","summary":[]},
            {"type":"message","role":"assistant","content":[
                {"type":"output_text","text":"Fixed ","annotations":[]},
                {"type":"refusal","refusal":""},
                {"type":"output_text","text":"text.","annotations":[]}
            ]},
            {"type":"function_call","name":"tool","arguments":"{}"}
        ]}
        """
        let provider = OpenAICompatibleLLMProvider()
        let result = try provider.parseResponseBody(Data(json.utf8), apiProtocol: .responses)
        XCTAssertEqual(result, "Fixed text.")
    }

    func testParseResponseBody_Responses_NoOutputText_ThrowsEmptyResponse() {
        let json = """
        {"id":"resp_1","status":"completed","output":[
            {"type":"reasoning","id":"rs_1","summary":[]},
            {"type":"message","role":"assistant","content":[
                {"type":"output_text","text":"","annotations":[]}
            ]}
        ]}
        """
        let provider = OpenAICompatibleLLMProvider()
        XCTAssertThrowsError(try provider.parseResponseBody(Data(json.utf8), apiProtocol: .responses)) { error in
            guard case LLMProviderError.emptyResponse = error else {
                return XCTFail("Expected emptyResponse, got \(error)")
            }
        }
    }
}

// MARK: - Helpers

private func makeOptions(
    contextTokens: Int = 131_072,
    maxOutputTokens: Int = 32_768,
    thinkingEnabled: Bool = true,
    thinkingEffort: LLMThinkingEffort = .medium
) -> LLMRequestOptions {
    LLMRequestOptions(
        contextTokens: contextTokens,
        maxOutputTokens: maxOutputTokens,
        thinkingEnabled: thinkingEnabled,
        thinkingEffort: thinkingEffort
    )
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(Int, String)] = []
    nonisolated(unsafe) static var capturedBodies: [[String: Any]] = []

    static func reset(_ responses: [(Int, String)]) {
        self.responses = responses
        capturedBodies = []
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.capturedBodies.append((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        }
        let (status, body) = Self.responses.isEmpty ? (500, "{}") : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Request Mapping

final class OpenAICompatibleLLMProviderRequestTests: XCTestCase {

    private let provider = OpenAICompatibleLLMProvider()

    func testRequestBody_ChatCompletions_UsesConfiguredLimitAndReasoningEffort() throws {
        let body = try jsonObject(provider.makeRequestBody(
            model: "qwen", text: "t", systemPrompt: "s", apiProtocol: .chatCompletions,
            options: makeOptions(maxOutputTokens: 20_000, thinkingEffort: .high)
        ))
        XCTAssertEqual(body["max_tokens"] as? Int, 20_000)
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
    }

    func testRequestBody_Responses_ThinkingOffSendsEffortNone() throws {
        let body = try jsonObject(provider.makeRequestBody(
            model: "gpt", text: "t", systemPrompt: "s", apiProtocol: .responses,
            options: makeOptions(thinkingEnabled: false)
        ))
        XCTAssertEqual(body["max_output_tokens"] as? Int, 32_768)
        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "none")
    }

    func testRequestBody_AnthropicMessages_UsesTopLevelSystemAndAdaptiveThinking() throws {
        let body = try jsonObject(provider.makeRequestBody(
            model: "claude", text: "hello", systemPrompt: "Fix typos", apiProtocol: .anthropicMessages,
            options: makeOptions(thinkingEffort: .low)
        ))
        XCTAssertEqual(body["system"] as? String, "Fix typos")
        XCTAssertEqual(body["max_tokens"] as? Int, 32_768)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "hello")
        let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "adaptive")
        let outputConfig = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(outputConfig["effort"] as? String, "low")
    }

    func testRequestBody_AnthropicMessages_ThinkingOffAndLegacyBudgetVariants() throws {
        let off = try jsonObject(provider.makeRequestBody(
            model: "claude", text: "t", systemPrompt: "s", apiProtocol: .anthropicMessages,
            options: makeOptions(thinkingEnabled: false)
        ))
        XCTAssertEqual((off["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertNil(off["output_config"])

        let legacy = try jsonObject(provider.makeRequestBody(
            model: "claude", text: "t", systemPrompt: "s", apiProtocol: .anthropicMessages,
            options: makeOptions(thinkingEffort: .low), thinking: .legacyBudget
        ))
        let thinking = try XCTUnwrap(legacy["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        XCTAssertEqual(thinking["budget_tokens"] as? Int, 2048)
        XCTAssertNil(legacy["output_config"])
    }

    func testRequestBody_OutputLimitShrinksToFitContext() throws {
        let body = try jsonObject(provider.makeRequestBody(
            model: "qwen", text: "t", systemPrompt: "s", apiProtocol: .chatCompletions,
            options: makeOptions(contextTokens: 8192, maxOutputTokens: 32_768)
        ))
        let inputTokens = TranscriptChunker.estimatedTokens("s") + TranscriptChunker.estimatedTokens("t")
        XCTAssertEqual(body["max_tokens"] as? Int, 8192 - inputTokens - 512)
    }

    func testRequestBody_ExtraBodyMergesAndOverridesTopLevelKeys() throws {
        let extra = OpenAICompatibleLLMProvider.parseJSONObject(
            #"{"chat_template_kwargs":{"enable_thinking":false},"max_tokens":1234}"#
        )
        let body = try jsonObject(provider.makeRequestBody(
            model: "qwen", text: "t", systemPrompt: "s", apiProtocol: .chatCompletions,
            options: makeOptions(), extraBody: extra
        ))
        XCTAssertEqual(body["max_tokens"] as? Int, 1234)
        let kwargs = try XCTUnwrap(body["chat_template_kwargs"] as? [String: Any])
        XCTAssertEqual(kwargs["enable_thinking"] as? Bool, false)
        XCTAssertTrue(OpenAICompatibleLLMProvider.parseJSONObject("not json").isEmpty)
    }

    func testRequestBody_OmittedThinkingVariant_RemovesAllReasoningFields() throws {
        for apiProtocol in OpenAIAPIProtocol.allCases {
            let body = try jsonObject(provider.makeRequestBody(
                model: "m", text: "t", systemPrompt: "s", apiProtocol: apiProtocol,
                options: makeOptions(), thinking: .omitted
            ))
            XCTAssertNil(body["reasoning_effort"], "\(apiProtocol)")
            XCTAssertNil(body["reasoning"], "\(apiProtocol)")
            XCTAssertNil(body["thinking"], "\(apiProtocol)")
            XCTAssertNil(body["output_config"], "\(apiProtocol)")
        }
    }

    func testMakeURLRequest_AnthropicUsesAPIKeyHeaderAndOtherProtocolsUseBearer() {
        let url = URL(string: "https://example.com/v1/messages")!
        let anthropic = provider.makeURLRequest(
            url: url, apiProtocol: .anthropicMessages, apiKey: "k", customHeaders: ["X-Test": "1"], body: Data()
        )
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(anthropic.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "X-Test"), "1")

        let chat = provider.makeURLRequest(
            url: url, apiProtocol: .chatCompletions, apiKey: "k", customHeaders: [:], body: Data()
        )
        XCTAssertEqual(chat.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertNil(chat.value(forHTTPHeaderField: "x-api-key"))
    }
}

// MARK: - Response Parsing

final class OpenAICompatibleLLMProviderResponseTests: XCTestCase {

    private let provider = OpenAICompatibleLLMProvider()

    func testParse_ChatCompletionsFinishReasonLength_ThrowsOutputTruncated() {
        let json = #"{"choices":[{"message":{"content":"Partial"},"finish_reason":"length"}]}"#
        assertThrows(json, .chatCompletions, expectTruncated: true)
    }

    func testParse_ResponsesIncomplete_ThrowsOutputTruncated() {
        let json = #"""
        {"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[
            {"type":"message","content":[{"type":"output_text","text":"Partial"}]}]}
        """#
        assertThrows(json, .responses, expectTruncated: true)
    }

    func testParse_AnthropicMessages_SkipsThinkingBlocksAndJoinsText() throws {
        let json = #"""
        {"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Fixed "},
            {"type":"text","text":"text."}],"stop_reason":"end_turn"}
        """#
        XCTAssertEqual(try provider.parseResponseBody(Data(json.utf8), apiProtocol: .anthropicMessages), "Fixed text.")
    }

    func testParse_AnthropicMaxTokens_ThrowsOutputTruncated() {
        let json = #"{"content":[{"type":"text","text":"Partial"}],"stop_reason":"max_tokens"}"#
        assertThrows(json, .anthropicMessages, expectTruncated: true)
    }

    func testParse_ContentFilterOrRefusal_ThrowsOutputRejected() {
        assertThrows(
            #"{"choices":[{"message":{"content":""},"finish_reason":"content_filter"}]}"#,
            .chatCompletions, expectTruncated: false
        )
        assertThrows(
            #"{"content":[{"type":"text","text":"I can't"}],"stop_reason":"refusal"}"#,
            .anthropicMessages, expectTruncated: false
        )
    }

    func testParse_LeadingThinkTagsAreStripped() throws {
        let json = #"{"choices":[{"message":{"content":"<think>\nreasoning\n</think>\n\nFixed text."}}]}"#
        XCTAssertEqual(try provider.parseResponseBody(Data(json.utf8), apiProtocol: .chatCompletions), "Fixed text.")
    }

    private func assertThrows(
        _ json: String, _ apiProtocol: OpenAIAPIProtocol, expectTruncated: Bool, line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try provider.parseResponseBody(Data(json.utf8), apiProtocol: apiProtocol), line: line
        ) { error in
            switch error {
            case LLMProviderError.outputTruncated where expectTruncated,
                 LLMProviderError.outputRejected where !expectTruncated:
                break
            default:
                XCTFail("Unexpected error \(error)", line: line)
            }
        }
    }
}

// MARK: - Transport

final class OpenAICompatibleLLMProviderTransportTests: XCTestCase {

    private static let suiteName = "OpenAICompatibleLLMProviderTransportTests"
    private var defaults: UserDefaults!
    private var provider: OpenAICompatibleLLMProvider!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        AppPreferences.store = defaults
        defaults.set("https://llm.example.com/v1", forKey: "openAIBaseURL")
        defaults.set("m", forKey: "openAIModel")
        defaults.set("chat_completions", forKey: "openAIAPIProtocol")
        provider = OpenAICompatibleLLMProvider(
            session: StubURLProtocol.makeSession(), variantCache: LLMThinkingVariantCache()
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        AppPreferences.store = .standard
        defaults = nil
        provider = nil
        super.tearDown()
    }

    func testCorrect_BadRequestMentioningReasoning_RetriesWithoutThinkingAndRemembersIt() async throws {
        StubURLProtocol.reset([
            (400, #"{"error":{"message":"Unrecognized request argument supplied: reasoning_effort"}}"#),
            (200, #"{"choices":[{"message":{"content":"Fixed."},"finish_reason":"stop"}]}"#),
            (200, #"{"choices":[{"message":{"content":"Again."},"finish_reason":"stop"}]}"#),
        ])

        let first = try await provider.correctTranscription("fixd", systemPrompt: "s")
        let second = try await provider.correctTranscription("agin", systemPrompt: "s")

        XCTAssertEqual(first, "Fixed.")
        XCTAssertEqual(second, "Again.")
        XCTAssertEqual(StubURLProtocol.capturedBodies.count, 3)
        XCTAssertEqual(StubURLProtocol.capturedBodies[0]["reasoning_effort"] as? String, "medium")
        XCTAssertNil(StubURLProtocol.capturedBodies[1]["reasoning_effort"])
        XCTAssertNil(StubURLProtocol.capturedBodies[2]["reasoning_effort"])
    }

    func testCorrect_ExtraBodyControlsThinking_DoesNotDowngrade() async {
        defaults.set(#"{"reasoning_effort":"high"}"#, forKey: "openAIExtraBody")
        StubURLProtocol.reset([(400, #"{"error":{"message":"reasoning_effort unsupported"}}"#)])
        do {
            _ = try await provider.correctTranscription("t", systemPrompt: "s")
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(StubURLProtocol.capturedBodies.count, 1)
        }
    }

    func testCorrect_MaxCompletionTokensHint_RetriesWithThatField() async throws {
        defaults.set(false, forKey: "openAIThinkingEnabled")
        StubURLProtocol.reset([
            (400, #"{"error":{"message":"Unsupported parameter: 'max_tokens'. Use 'max_completion_tokens' instead."}}"#),
            (200, #"{"choices":[{"message":{"content":"Fixed."}}]}"#),
        ])
        _ = try await provider.correctTranscription("t", systemPrompt: "s")
        XCTAssertNil(StubURLProtocol.capturedBodies[1]["max_tokens"])
        XCTAssertNotNil(StubURLProtocol.capturedBodies[1]["max_completion_tokens"])
    }

    func testCorrect_ErrorStatusIsPreservedForClassification() async {
        for (status, kind) in [(503, LLMFailureKind.transient), (404, .permanent), (400, .perRequest)] {
            StubURLProtocol.reset([(status, #"{"error":{"message":"failure"}}"#)])
            do {
                _ = try await provider.correctTranscription("t", systemPrompt: "s")
                XCTFail("Expected error for \(status)")
            } catch let error as LLMProviderError {
                guard case .httpError(let code, _) = error else { return XCTFail("\(status): got \(error)") }
                XCTAssertEqual(code, status)
                XCTAssertEqual(error.failureKind, kind)
            } catch {
                XCTFail("Unexpected \(error)")
            }
        }
    }

    func testFastRetry_OnlyForConnectionsThatDropImmediately() {
        let quick = Duration.milliseconds(100)
        XCTAssertTrue(OpenAICompatibleLLMProvider.isFastRetryable(URLError(.networkConnectionLost), after: quick))
        XCTAssertTrue(OpenAICompatibleLLMProvider.isFastRetryable(URLError(.cannotConnectToHost), after: quick))
        XCTAssertFalse(OpenAICompatibleLLMProvider.isFastRetryable(URLError(.networkConnectionLost), after: .seconds(60)))
        XCTAssertFalse(OpenAICompatibleLLMProvider.isFastRetryable(URLError(.timedOut), after: quick))
        XCTAssertFalse(OpenAICompatibleLLMProvider.isFastRetryable(URLError(.notConnectedToInternet), after: quick))
    }
}
