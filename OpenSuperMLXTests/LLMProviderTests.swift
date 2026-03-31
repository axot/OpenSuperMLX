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

    // MARK: - User Facing Messages

    func testUserFacingMessage_AuthenticationFailed() {
        let error = LLMProviderError.authenticationFailed(provider: "Test", detail: "bad key")
        XCTAssertEqual(error.userFacingMessage, "Invalid API key. Check Settings → LLM.")
    }

    func testUserFacingMessage_NotConfigured() {
        let error = LLMProviderError.notConfigured(provider: "Test")
        XCTAssertEqual(error.userFacingMessage, "LLM is not configured. Check Settings → LLM.")
    }

    func testUserFacingMessage_EmptyResponse() {
        let error = LLMProviderError.emptyResponse
        XCTAssertEqual(error.userFacingMessage, "LLM returned an empty result. Try a different model or prompt.")
    }

    func testUserFacingMessage_Timeout() {
        let error = LLMProviderError.timeout(seconds: 30)
        XCTAssertEqual(error.userFacingMessage, "LLM request timed out.")
    }

    func testUserFacingMessage_NetworkError() {
        let error = LLMProviderError.networkError(underlying: URLError(.notConnectedToInternet))
        XCTAssertEqual(error.userFacingMessage, "Cannot connect to LLM server. Check the API endpoint.")
    }

    func testUserFacingMessage_RateLimited() {
        let error = LLMProviderError.rateLimited(provider: "Test", retryAfter: nil)
        XCTAssertEqual(error.userFacingMessage, "Rate limit reached. Please wait and try again.")
    }

    func testUserFacingMessage_ApiError_ModelNotFound() {
        let error = LLMProviderError.apiError(provider: "Test", message: "The model 'xyz' does not exist", code: nil)
        XCTAssertEqual(error.userFacingMessage, "Model not found. Check the model name in Settings → LLM.")
    }

    func testUserFacingMessage_ApiError_Generic() {
        let error = LLMProviderError.apiError(provider: "Test", message: "Bad request", code: "400")
        XCTAssertEqual(error.userFacingMessage, "LLM correction failed. Check Settings → LLM.")
    }

    func testUserFacingMessage_HttpError_404() {
        let error = LLMProviderError.httpError(statusCode: 404, message: "Not Found")
        XCTAssertEqual(error.userFacingMessage, "Model not found. Check the model name in Settings → LLM.")
    }

    func testUserFacingMessage_HttpError_401() {
        let error = LLMProviderError.httpError(statusCode: 401, message: "Unauthorized")
        XCTAssertEqual(error.userFacingMessage, "Invalid API key. Check Settings → LLM.")
    }

    func testUserFacingMessage_HttpError_429() {
        let error = LLMProviderError.httpError(statusCode: 429, message: "Too Many Requests")
        XCTAssertEqual(error.userFacingMessage, "Rate limit reached. Please wait and try again.")
    }

    func testUserFacingMessage_HttpError_500() {
        let error = LLMProviderError.httpError(statusCode: 500, message: "Internal Server Error")
        XCTAssertEqual(error.userFacingMessage, "LLM correction failed. Check Settings → LLM.")
    }

    func testUserFacingMessage_HttpError_401WithNotFoundMessage_PrioritizesStatusCode() {
        let error = LLMProviderError.httpError(statusCode: 401, message: "Resource not found")
        XCTAssertEqual(error.userFacingMessage, "Invalid API key. Check Settings → LLM.")
    }

    // MARK: - Provider Name

    func testProviderName_AuthenticationFailed() {
        let error = LLMProviderError.authenticationFailed(provider: "OpenAI", detail: "bad key")
        XCTAssertEqual(error.providerName, "OpenAI")
    }

    func testProviderName_NetworkError_ReturnsNil() {
        let error = LLMProviderError.networkError(underlying: URLError(.timedOut))
        XCTAssertNil(error.providerName)
    }
}
