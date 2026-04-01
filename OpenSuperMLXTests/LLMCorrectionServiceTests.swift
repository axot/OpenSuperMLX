// LLMCorrectionServiceTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

@MainActor
final class LLMCorrectionServiceTests: XCTestCase {

    private static let suiteName = "LLMCorrectionServiceTests"
    private var mockProvider: MockLLMProvider!
    private var sut: LLMCorrectionService!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        AppPreferences.store = defaults
        mockProvider = MockLLMProvider()
        sut = LLMCorrectionService(providerFactory: { [mockProvider] in mockProvider! })
        defaults.set(true, forKey: "llmCorrectionEnabled")
        defaults.set("bedrock", forKey: "llmProvider")
        defaults.set(false, forKey: "useCustomCorrectionPrompt")
    }

    override func tearDown() async throws {
        sut = nil
        mockProvider = nil
        defaults.removePersistentDomain(forName: Self.suiteName)
        AppPreferences.store = .standard
        defaults = nil
        try await super.tearDown()
    }

    // MARK: - Enabled/Disabled

    func testCorrectTranscription_WhenDisabled_ReturnsOriginalText() async {
        defaults.set(false, forKey: "llmCorrectionEnabled")
        let result = await sut.correctTranscription("hello world")
        XCTAssertEqual(result, "hello world")
        XCTAssertEqual(mockProvider.correctCallCount, 0)
    }

    func testCorrectTranscription_WhenForceEnabled_BypassesDisabledCheck() async {
        defaults.set(false, forKey: "llmCorrectionEnabled")
        mockProvider.correctResult = "corrected"
        let result = await sut.correctTranscription("hello world", forceEnabled: true)
        XCTAssertEqual(result, "corrected")
        XCTAssertEqual(mockProvider.correctCallCount, 1)
    }

    // MARK: - Input Guards

    func testCorrectTranscription_EmptyText_ReturnsOriginal() async {
        let result = await sut.correctTranscription("   ")
        XCTAssertEqual(result, "   ")
        XCTAssertEqual(mockProvider.correctCallCount, 0)
    }

    func testCorrectTranscription_NoSpeechDetected_ReturnsOriginal() async {
        let result = await sut.correctTranscription("No speech detected in the audio")
        XCTAssertEqual(result, "No speech detected in the audio")
        XCTAssertEqual(mockProvider.correctCallCount, 0)
    }

    // MARK: - Provider Interaction

    func testCorrectTranscription_ProviderNotConfigured_ReturnsOriginal() async {
        mockProvider.isConfigured = false
        let result = await sut.correctTranscription("hello")
        XCTAssertEqual(result, "hello")
        XCTAssertEqual(mockProvider.correctCallCount, 0)
    }

    func testCorrectTranscription_ProviderReturnsResult_ReturnsTrimmed() async {
        mockProvider.correctResult = "  corrected text  "
        let result = await sut.correctTranscription("hello")
        XCTAssertEqual(result, "corrected text")
    }

    func testCorrectTranscription_ProviderReturnsEmpty_ReturnsOriginal() async {
        mockProvider.correctResult = ""
        let result = await sut.correctTranscription("hello")
        XCTAssertEqual(result, "hello")
    }

    func testCorrectTranscription_ProviderThrows_ReturnsOriginal() async {
        mockProvider.shouldThrowError = LLMProviderError.networkError(underlying: URLError(.notConnectedToInternet))
        let result = await sut.correctTranscription("hello")
        XCTAssertEqual(result, "hello")
    }

    func testCorrectTranscription_PassesBuiltSystemPrompt() async {
        defaults.set(true, forKey: "useCustomCorrectionPrompt")
        defaults.set("Test custom prompt", forKey: "customCorrectionPrompt")
        mockProvider.correctResult = "corrected"
        _ = await sut.correctTranscription("hello")
        let expectedPrompt = LLMCorrectionService.buildSystemPrompt(userPrompt: "Test custom prompt")
        XCTAssertEqual(mockProvider.lastSystemPrompt, expectedPrompt)
    }

    func testCorrectTranscription_PassesWrappedText() async {
        mockProvider.correctResult = "corrected"
        _ = await sut.correctTranscription("  hello world  ")
        XCTAssertEqual(mockProvider.lastText, "<transcription>\nhello world\n</transcription>")
    }
}
