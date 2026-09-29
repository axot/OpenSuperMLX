// BedrockLLMProviderTests.swift
// OpenSuperMLXTests

import XCTest

import AWSBedrockRuntime
import Smithy

@testable import OpenSuperMLX

final class BedrockLLMProviderTests: XCTestCase {

    private static let suiteName = "BedrockLLMProviderTests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        AppPreferences.store = defaults
        defaults.set("us-east-1", forKey: "bedrockRegion")
        defaults.set("anthropic.claude-3-haiku-20240307-v1:0", forKey: "bedrockModelId")
        defaults.set("profile", forKey: "bedrockAuthMode")
        defaults.set("default", forKey: "bedrockProfileName")
        defaults.set("", forKey: "bedrockAccessKey")
        defaults.set("", forKey: "bedrockSecretKey")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: Self.suiteName)
        AppPreferences.store = .standard
        defaults = nil
        try await super.tearDown()
    }

    // MARK: - Display Name

    func testDisplayName_ReturnsAWSBedrock() {
        let provider = BedrockLLMProvider()
        XCTAssertEqual(provider.displayName, "AWS Bedrock")
    }

    // MARK: - isConfigured

    func testIsConfigured_WithRegionAndModelId_ReturnsTrue() {
        let provider = BedrockLLMProvider()
        XCTAssertTrue(provider.isConfigured)
    }

    func testIsConfigured_MissingRegion_ReturnsFalse() {
        defaults.set("", forKey: "bedrockRegion")
        let provider = BedrockLLMProvider()
        XCTAssertFalse(provider.isConfigured)
    }

    func testIsConfigured_MissingModelId_ReturnsFalse() {
        defaults.set("", forKey: "bedrockModelId")
        let provider = BedrockLLMProvider()
        XCTAssertFalse(provider.isConfigured)
    }

    func testIsConfigured_AccessKeyMode_RequiresKeys() {
        defaults.set("accessKey", forKey: "bedrockAuthMode")
        defaults.set("AKIAIOSFODNN7EXAMPLE", forKey: "bedrockAccessKey")
        defaults.set("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", forKey: "bedrockSecretKey")
        let provider = BedrockLLMProvider()
        XCTAssertTrue(provider.isConfigured)
    }

    func testIsConfigured_AccessKeyMode_MissingSecretKey_ReturnsFalse() {
        defaults.set("accessKey", forKey: "bedrockAuthMode")
        defaults.set("AKIAIOSFODNN7EXAMPLE", forKey: "bedrockAccessKey")
        defaults.set("", forKey: "bedrockSecretKey")
        let provider = BedrockLLMProvider()
        XCTAssertFalse(provider.isConfigured)
    }

    func testIsConfigured_ProfileMode_DoesNotRequireKeys() {
        defaults.set("profile", forKey: "bedrockAuthMode")
        defaults.set("", forKey: "bedrockAccessKey")
        defaults.set("", forKey: "bedrockSecretKey")
        let provider = BedrockLLMProvider()
        XCTAssertTrue(provider.isConfigured)
    }

    // MARK: - Converse Input

    func testMakeConverseInput_OmitsTemperature() throws {
        let provider = BedrockLLMProvider()
        let input = provider.makeConverseInput(
            modelId: "anthropic.claude-3-haiku-20240307-v1:0",
            systemPrompt: "Fix typos",
            text: " Corect text ",
            options: LLMRequestOptions(
                contextTokens: 200_000, maxOutputTokens: 4096, thinkingEnabled: false, thinkingEffort: .medium
            )
        )

        XCTAssertEqual(input.modelId, "anthropic.claude-3-haiku-20240307-v1:0")
        XCTAssertEqual(input.inferenceConfig?.maxTokens, 4096)
        XCTAssertNil(input.inferenceConfig?.temperature, "Reasoning models reject requests that set temperature")
    }
}

// MARK: - Request Options, Response Parsing & Error Mapping

final class BedrockLLMProviderResponseTests: XCTestCase {

    private let provider = BedrockLLMProvider()

    func testConverseInput_ThinkingDisabled_UsesConfiguredMaxTokensWithoutExtraFields() {
        let input = provider.makeConverseInput(
            modelId: "m", systemPrompt: "s", text: "t",
            options: LLMRequestOptions(
                contextTokens: 200_000, maxOutputTokens: 16_000, thinkingEnabled: false, thinkingEffort: .high
            )
        )
        XCTAssertEqual(input.inferenceConfig?.maxTokens, 16_000)
        XCTAssertNil(input.additionalModelRequestFields)
    }

    func testConverseInput_ThinkingEnabled_UsesAdaptiveThenLegacyBudgetThenNothing() throws {
        let options = LLMRequestOptions(
            contextTokens: 200_000, maxOutputTokens: 32_000, thinkingEnabled: true, thinkingEffort: .medium
        )
        let input = provider.makeConverseInput(modelId: "m", systemPrompt: "s", text: "t", options: options)
        let fields = try XCTUnwrap(input.additionalModelRequestFields).asStringMap()
        let thinking = try XCTUnwrap(fields["thinking"]).asStringMap()
        XCTAssertEqual(try thinking["type"]?.asString(), "adaptive")
        let outputConfig = try XCTUnwrap(fields["output_config"]).asStringMap()
        XCTAssertEqual(try outputConfig["effort"]?.asString(), "medium")

        let legacy = provider.makeConverseInput(
            modelId: "m", systemPrompt: "s", text: "t", options: options, thinking: .legacyBudget
        )
        let legacyThinking = try XCTUnwrap(try XCTUnwrap(legacy.additionalModelRequestFields).asStringMap()["thinking"])
            .asStringMap()
        XCTAssertEqual(try legacyThinking["type"]?.asString(), "enabled")
        XCTAssertEqual(try legacyThinking["budget_tokens"]?.asInteger(), 8192)

        let withoutThinking = provider.makeConverseInput(
            modelId: "m", systemPrompt: "s", text: "t", options: options, thinking: .omitted
        )
        XCTAssertNil(withoutThinking.additionalModelRequestFields)
    }

    func testExtractText_SkipsReasoningBlocksAndJoinsText() throws {
        let output = ConverseOutput(
            output: .message(BedrockRuntimeClientTypes.Message(
                content: [
                    .reasoningcontent(.reasoningtext(BedrockRuntimeClientTypes.ReasoningTextBlock(text: "hmm"))),
                    .text("Fixed "),
                    .text("text."),
                ],
                role: .assistant
            )),
            stopReason: .endTurn
        )
        XCTAssertEqual(try BedrockLLMProvider.extractText(from: output), "Fixed text.")
    }

    func testExtractText_MaxTokensOrContextExceeded_ThrowsOutputTruncated() {
        for reason: BedrockRuntimeClientTypes.StopReason in [.maxTokens, .modelContextWindowExceeded] {
            let output = ConverseOutput(
                output: .message(BedrockRuntimeClientTypes.Message(content: [.text("Partial")], role: .assistant)),
                stopReason: reason
            )
            XCTAssertThrowsError(try BedrockLLMProvider.extractText(from: output)) { error in
                guard case LLMProviderError.outputTruncated = error else {
                    return XCTFail("Expected outputTruncated for \(reason), got \(error)")
                }
            }
        }
    }

    func testMapError_TypedServiceErrorsMapToClassifiedProviderErrors() {
        XCTAssertEqual(BedrockLLMProvider.mapError(AccessDeniedException(message: "denied")).failureKind, .permanent)
        XCTAssertEqual(BedrockLLMProvider.mapError(ResourceNotFoundException(message: "no model")).failureKind, .permanent)
        XCTAssertEqual(BedrockLLMProvider.mapError(ThrottlingException(message: "slow down")).failureKind, .transient)
        XCTAssertEqual(BedrockLLMProvider.mapError(ServiceUnavailableException(message: "busy")).failureKind, .transient)
        XCTAssertEqual(BedrockLLMProvider.mapError(ValidationException(message: "too long")).failureKind, .perRequest)
        XCTAssertEqual(BedrockLLMProvider.mapError(URLError(.notConnectedToInternet)).failureKind, .transient)
    }

    func testMapError_ThinkingRejectionsAreOnlyDetectedOnValidationErrors() {
        XCTAssertTrue(BedrockLLMProvider.mapError(
            ValidationException(message: "extraneous key [thinking] is not permitted")
        ).rejectsThinkingParameters)
        XCTAssertFalse(BedrockLLMProvider.mapError(ValidationException(message: "input is too long")).rejectsThinkingParameters)
        XCTAssertFalse(BedrockLLMProvider.mapError(ThrottlingException(message: "thinking")).rejectsThinkingParameters)
    }
}
