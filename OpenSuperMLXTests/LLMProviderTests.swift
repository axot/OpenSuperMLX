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

    // MARK: - OpenAIAPIProtocol

    func testOpenAIAPIProtocol_DisplayNames() {
        XCTAssertEqual(OpenAIAPIProtocol.chatCompletions.displayName, "Chat Completions")
        XCTAssertEqual(OpenAIAPIProtocol.responses.displayName, "Responses")
        XCTAssertEqual(OpenAIAPIProtocol.anthropicMessages.displayName, "Anthropic Messages")
    }

    func testOpenAIAPIProtocol_EndpointPaths() {
        XCTAssertEqual(OpenAIAPIProtocol.chatCompletions.endpointPath, "chat/completions")
        XCTAssertEqual(OpenAIAPIProtocol.responses.endpointPath, "responses")
        XCTAssertEqual(OpenAIAPIProtocol.anthropicMessages.endpointPath, "messages")
    }

    func testOpenAIAPIProtocol_RawValueRoundTrips() {
        XCTAssertEqual(OpenAIAPIProtocol(rawValue: "chat_completions"), .chatCompletions)
        XCTAssertEqual(OpenAIAPIProtocol(rawValue: "responses"), .responses)
        XCTAssertEqual(OpenAIAPIProtocol(rawValue: "anthropic_messages"), .anthropicMessages)
        XCTAssertNil(OpenAIAPIProtocol(rawValue: "unknown"))
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

    func testUserFacingMessage_HttpError_ModelDoesNotExist() {
        let error = LLMProviderError.httpError(statusCode: 400, message: "The model 'xyz' does not exist")
        XCTAssertEqual(error.userFacingMessage, "Model not found. Check the model name in Settings → LLM.")
    }

    func testUserFacingMessage_HttpError_Generic() {
        let error = LLMProviderError.httpError(statusCode: 400, message: "Bad request")
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

// MARK: - Failure Kind & Request Options

final class LLMProviderFailureKindTests: XCTestCase {

    func testFailureKind_NetworkTimeoutRateLimitAndServerErrorsAreTransient() {
        let transient: [LLMProviderError] = [
            .networkError(underlying: URLError(.notConnectedToInternet)),
            .timeout(seconds: 30),
            .rateLimited(provider: "Test", retryAfter: nil),
            .httpError(statusCode: 503, message: "Service Unavailable"),
            .httpError(statusCode: 408, message: "Request Timeout"),
            .httpError(statusCode: 429, message: "Too Many Requests"),
        ]
        for error in transient {
            XCTAssertEqual(error.failureKind, .transient, "\(error)")
        }
    }

    func testFailureKind_ConfigurationAndAuthErrorsArePermanent() {
        let permanent: [LLMProviderError] = [
            .notConfigured(provider: "Test"),
            .authenticationFailed(provider: "Test", detail: "bad key"),
            .httpError(statusCode: 401, message: ""),
            .httpError(statusCode: 403, message: ""),
            .httpError(statusCode: 404, message: ""),
        ]
        for error in permanent {
            XCTAssertEqual(error.failureKind, .permanent, "\(error)")
        }
    }

    func testFailureKind_TruncationEmptyAndBadRequestArePerRequest() {
        let perRequest: [LLMProviderError] = [
            .outputTruncated(provider: "Test"),
            .outputRejected(provider: "Test", reason: "content_filter"),
            .emptyResponse,
            .httpError(statusCode: 400, message: "context too long"),
            .httpError(statusCode: 413, message: ""),
            .requestTooLarge(provider: "Test", detail: "maximum context length exceeded"),
        ]
        for error in perRequest {
            XCTAssertEqual(error.failureKind, .perRequest, "\(error)")
        }
    }

    func testOutputTruncated_UserFacingMessageExplainsCutOff() {
        let error = LLMProviderError.outputTruncated(provider: "Test")
        XCTAssertEqual(error.errorDescription, "Test stopped before finishing the output.")
        XCTAssertEqual(error.userFacingMessage, "LLM output was cut off. Original text kept.")
    }

    func testFromHTTP_ClassifiesTokenLimitsOnceAndDetectsThinkingRejections() {
        func classify(_ status: Int, _ message: String) -> LLMProviderError {
            LLMProviderError.fromHTTP(statusCode: status, message: message, provider: "Test")
        }
        guard case .requestTooLarge = classify(400, "max_tokens is too large: 200000"),
              case .requestTooLarge = classify(400, "This model's maximum context length is 32768 tokens"),
              case .requestTooLarge = classify(400, "Input is too long for requested model."),
              case .httpError(400, _) = classify(400, "content_filter triggered"),
              case .authenticationFailed = classify(401, "bad key"),
              case .rateLimited = classify(429, "slow down")
        else {
            return XCTFail("Unexpected classification")
        }

        XCTAssertTrue(classify(400, "Unrecognized request argument supplied: reasoning_effort").rejectsThinkingParameters)
        XCTAssertTrue(classify(400, "thinking.budget_tokens must be less than max_tokens").rejectsThinkingParameters)
        XCTAssertFalse(classify(400, "content_filter triggered").rejectsThinkingParameters)
        XCTAssertFalse(classify(429, "reasoning quota").rejectsThinkingParameters)
    }

    func testVariantCache_RemembersDowngradeAndClampsToShorterVariantLists() async throws {
        let cache = LLMThinkingVariantCache()
        let first = try await cache.firstAccepted(key: "k", variants: [.primary, .omitted]) { variant in
            if variant == .primary { throw LLMProviderError.httpError(statusCode: 400, message: "reasoning unsupported") }
            return variant
        }
        let remembered = try await cache.firstAccepted(key: "k", variants: [.primary, .omitted]) { $0 }
        let shorterList = try await cache.firstAccepted(key: "k", variants: [.primary]) { $0 }

        XCTAssertEqual(first, .omitted)
        XCTAssertEqual(remembered, .omitted)
        XCTAssertEqual(shorterList, .primary)
    }

    func testThinkingBudget_ScalesWithEffortAndStaysBelowHalfTheOutputLimit() {
        var options = LLMRequestOptions(
            contextTokens: 131_072, maxOutputTokens: 32_768, thinkingEnabled: true, thinkingEffort: .low
        )
        XCTAssertEqual(options.thinkingBudgetTokens, 2048)
        options.thinkingEffort = .medium
        XCTAssertEqual(options.thinkingBudgetTokens, 8192)
        options.thinkingEffort = .high
        XCTAssertEqual(options.thinkingBudgetTokens, 16_384)
        options.maxOutputTokens = 4096
        XCTAssertEqual(options.thinkingBudgetTokens, 2048)
    }

    func testReservedThinkingTokens_ZeroWhenThinkingDisabled() {
        let enabled = LLMRequestOptions(
            contextTokens: 200_000, maxOutputTokens: 32_768, thinkingEnabled: true, thinkingEffort: .medium
        )
        var disabled = enabled
        disabled.thinkingEnabled = false
        XCTAssertEqual(enabled.reservedThinkingTokens, 8192)
        XCTAssertEqual(disabled.reservedThinkingTokens, 0)
    }
}
