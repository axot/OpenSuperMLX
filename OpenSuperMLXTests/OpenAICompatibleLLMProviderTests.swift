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

    // MARK: - Request Body

    func testMakeRequestBody_ChatCompletions_EncodesMessagesArray() throws {
        let provider = OpenAICompatibleLLMProvider()
        let data = try provider.makeRequestBody(
            model: "gpt-4o-mini",
            text: " Corect text ",
            systemPrompt: "Fix typos",
            apiProtocol: .chatCompletions
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
            apiProtocol: .responses
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
