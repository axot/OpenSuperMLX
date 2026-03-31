// LLMProviderTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class LLMProviderTests: XCTestCase {

    // MARK: - MockLLMProvider Conformance

    func testMockProvider_ConformsToProtocol() {
        let provider: LLMProvider = MockLLMProvider()
        XCTAssertEqual(provider.displayName, "Mock")
        XCTAssertTrue(provider.isConfigured)
    }

    // MARK: - LLMProviderType

    func testProviderType_AllCases() {
        let cases = LLMProviderType.allCases
        XCTAssertEqual(cases.count, 2)
        XCTAssertEqual(cases[0], .bedrock)
        XCTAssertEqual(cases[1], .openai)
    }

    func testProviderType_DisplayNames() {
        XCTAssertEqual(LLMProviderType.bedrock.displayName, "AWS Bedrock")
        XCTAssertEqual(LLMProviderType.openai.displayName, "OpenAI Compatible")
    }

    func testProviderType_RawValueRoundTrips() {
        XCTAssertEqual(LLMProviderType(rawValue: "bedrock"), .bedrock)
        XCTAssertEqual(LLMProviderType(rawValue: "openai"), .openai)
        XCTAssertNil(LLMProviderType(rawValue: "unknown"))
    }

    // MARK: - LLMProviderError

    func testProviderError_ErrorDescriptions() {
        XCTAssertEqual(
            LLMProviderError.notConfigured(provider: "Test").errorDescription,
            "Test is not configured."
        )
        XCTAssertEqual(
            LLMProviderError.emptyResponse.errorDescription,
            "LLM returned an empty response."
        )
        XCTAssertEqual(
            LLMProviderError.timeout(seconds: 30).errorDescription,
            "LLM request timed out after 30 seconds."
        )
        XCTAssertEqual(
            LLMProviderError.cancelled.errorDescription,
            "LLM request was cancelled."
        )
        XCTAssertEqual(
            LLMProviderError.httpError(statusCode: 500, message: "Internal Error").errorDescription,
            "HTTP 500: Internal Error"
        )
        XCTAssertEqual(
            LLMProviderError.apiError(provider: "Test", message: "Bad request", code: "400").errorDescription,
            "Bad request"
        )
        XCTAssertEqual(
            LLMProviderError.authenticationFailed(provider: "Test", detail: "Invalid key").errorDescription,
            "Test authentication failed: Invalid key"
        )
        XCTAssertEqual(
            LLMProviderError.rateLimited(provider: "Test", retryAfter: 60).errorDescription,
            "Test rate limit exceeded. Try again later."
        )
    }
}
