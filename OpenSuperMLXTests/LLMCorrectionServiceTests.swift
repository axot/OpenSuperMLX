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
        XCTAssertNil(sut.lastErrorMessage)
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
        XCTAssertNil(sut.lastErrorMessage)
    }

    func testCorrectTranscription_NoSpeechDetected_ReturnsOriginal() async {
        let result = await sut.correctTranscription("No speech detected in the audio")
        XCTAssertEqual(result, "No speech detected in the audio")
        XCTAssertEqual(mockProvider.correctCallCount, 0)
        XCTAssertNil(sut.lastErrorMessage)
    }

    // MARK: - Provider Interaction

    func testCorrectTranscription_ProviderNotConfigured_PreservesTextAndSetsError() async {
        for forceEnabled in [false, true] {
            defaults.set(!forceEnabled, forKey: "llmCorrectionEnabled")
            mockProvider.isConfigured = false

            let result = await sut.correctTranscription("hello", forceEnabled: forceEnabled)

            XCTAssertEqual(result, "hello")
            XCTAssertEqual(mockProvider.correctCallCount, 0)
            XCTAssertEqual(
                sut.lastErrorMessage,
                LLMProviderError.notConfigured(provider: mockProvider.displayName).userFacingMessage
            )
        }
    }

    func testCorrectTranscription_ProviderReturnsResult_ReturnsTrimmed() async {
        mockProvider.isConfigured = false
        _ = await sut.correctTranscription("hello")
        XCTAssertNotNil(sut.lastErrorMessage)

        mockProvider.isConfigured = true
        mockProvider.correctResult = "  corrected text  "
        let result = await sut.correctTranscription("hello")
        XCTAssertEqual(result, "corrected text")
        XCTAssertNil(sut.lastErrorMessage)
    }

    func testCorrectTranscription_ProviderReturnsEmpty_ReturnsOriginal() async {
        mockProvider.correctResult = ""
        let result = await sut.correctTranscription("hello")
        XCTAssertEqual(result, "hello")
        // Regression: empty response must set lastErrorMessage so the toast surface fires.
        XCTAssertEqual(sut.lastErrorMessage, LLMCorrectionService.emptyCorrectionMessage)
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

// MARK: - Long Transcripts
private let sentence = "あいうえおかきくけこさしすせそたちつてと。"

/// About 2,100 estimated tokens: over the ~744-token capacity of a 1,024-token output limit.
private let longText = String(repeating: sentence, count: 100)

private func unwrap(_ text: String) -> String {
    LLMCorrectionService.stripTranscriptionTags(text)
}

private func removingMarkers(_ text: String) -> String {
    text.replacingOccurrences(of: #"【\d+】"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: "\n\n", with: "")
}

// MARK: - Single Request vs Chunks

@MainActor
final class LLMCorrectionServiceChunkingTests: XCTestCase {

    private static let suiteName = "LLMCorrectionServiceChunkingTests"
    private var defaults: UserDefaults!
    private var mockProvider: MockLLMProvider!
    private var sut: LLMCorrectionService!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        AppPreferences.store = defaults
        defaults.set(true, forKey: "llmCorrectionEnabled")
        mockProvider = MockLLMProvider()
        mockProvider.handler = { text, _, index in "【\(index)】" + unwrap(text) }
        sut = LLMCorrectionService(providerFactory: { [mockProvider] in mockProvider! })
    }

    override func tearDown() async throws {
        sut = nil
        mockProvider = nil
        defaults.removePersistentDomain(forName: Self.suiteName)
        AppPreferences.store = .standard
        defaults = nil
        try await super.tearDown()
    }

    private func useSmallOutputLimit() {
        mockProvider.requestOptions.maxOutputTokens = 1024
    }

    func testCorrect_TextWithinCapacity_UsesOneRequestAndAsksForParagraphs() async {
        let text = String(repeating: "これはテストです。", count: 40)

        let outcome = await sut.correct(text)

        XCTAssertEqual(outcome.mode, .single)
        XCTAssertEqual(outcome.chunkCount, 1)
        XCTAssertEqual(mockProvider.correctCallCount, 1)
        XCTAssertEqual(outcome.text, "【0】" + text)
        XCTAssertTrue(mockProvider.lastSystemPrompt?.hasSuffix(LLMCorrectionService.paragraphInstruction) == true)
    }

    func testCorrect_TextOverCapacity_SplitsIntoBalancedChunksInOrder() async {
        useSmallOutputLimit()

        let outcome = await sut.correct(longText)

        XCTAssertEqual(outcome.mode, .chunked)
        XCTAssertEqual(outcome.chunkCount, 3)
        XCTAssertEqual(mockProvider.correctCallCount, 3)
        XCTAssertNil(outcome.errorMessage)
        XCTAssertTrue(outcome.text.hasPrefix("【0】"))
        XCTAssertFalse(outcome.text.contains("\n\n"))
        XCTAssertEqual(removingMarkers(outcome.text), longText)
        XCTAssertTrue(mockProvider.calls.allSatisfy {
            $0.systemPrompt.contains(LLMCorrectionService.chunkEdgeInstruction)
        })
    }

    func testCorrect_SingleRequestTruncated_RetriesInAtLeastTwoChunks() async {
        mockProvider.handler = { text, _, index in
            if index == 0 { throw LLMProviderError.outputTruncated(provider: "Mock") }
            return "【\(index)】" + unwrap(text)
        }

        let outcome = await sut.correct(longText)

        XCTAssertEqual(outcome.mode, .chunked)
        XCTAssertGreaterThanOrEqual(outcome.chunkCount, 2)
        XCTAssertEqual(mockProvider.correctCallCount, outcome.chunkCount + 1)
        XCTAssertEqual(removingMarkers(outcome.text), longText)
    }

    func testCorrect_FirstChunkHitsModelLimit_StopsAndSuggestsLoweringSettings() async {
        useSmallOutputLimit()
        let limitError = LLMProviderError.requestTooLarge(provider: "Mock", detail: "max_tokens is too large: 1024")
        mockProvider.handler = { _, _, _ in throw limitError }

        let outcome = await sut.correct(longText)

        XCTAssertEqual(mockProvider.correctCallCount, 1)
        XCTAssertEqual(outcome.text, longText)
        XCTAssertEqual(outcome.failedChunkCount, outcome.chunkCount)
        XCTAssertEqual(outcome.errorMessage, limitError.userFacingMessage)
    }

    func testCorrect_ContentErrorOnOneChunk_KeepsThatChunkAndContinues() async {
        useSmallOutputLimit()
        mockProvider.handler = { text, _, index in
            if index == 1 { throw LLMProviderError.httpError(statusCode: 400, message: "content_filter triggered") }
            return "【\(index)】" + unwrap(text)
        }

        let outcome = await sut.correct(longText)

        XCTAssertEqual(mockProvider.correctCallCount, 3)
        XCTAssertEqual(outcome.failedChunkCount, 1)
        XCTAssertEqual(outcome.errorMessage, "LLM correction failed for 1 of 3 segments; original text kept for those.")
        XCTAssertTrue(outcome.text.contains("【0】") && outcome.text.contains("【2】"))
        XCTAssertFalse(outcome.text.contains("【1】"))
        XCTAssertEqual(removingMarkers(outcome.text), longText)
    }

    func testCorrect_TimeoutOnOneChunk_KeepsThatChunkAndContinues() async {
        useSmallOutputLimit()
        mockProvider.handler = { text, _, index in
            if index == 1 { throw LLMProviderError.timeout(seconds: 140) }
            return "【\(index)】" + unwrap(text)
        }

        let outcome = await sut.correct(longText)

        XCTAssertEqual(mockProvider.correctCallCount, 3)
        XCTAssertEqual(outcome.failedChunkCount, 1)
        XCTAssertTrue(outcome.text.contains("【2】"))
    }

    func testCorrect_TransientChunkError_StopsSendingRemainingChunks() async {
        useSmallOutputLimit()
        mockProvider.handler = { text, _, index in
            if index == 1 { throw LLMProviderError.networkError(underlying: URLError(.notConnectedToInternet)) }
            return "【\(index)】" + unwrap(text)
        }

        let outcome = await sut.correct(longText)

        XCTAssertEqual(mockProvider.correctCallCount, 2)
        XCTAssertEqual(outcome.failedChunkCount, 2)
        XCTAssertEqual(removingMarkers(outcome.text), longText)
    }

    func testCorrect_ContextTooSmallForPrompt_SkipsRequestAndExplains() async {
        mockProvider.requestOptions.contextTokens = 1024

        let outcome = await sut.correct(longText)

        XCTAssertEqual(mockProvider.correctCallCount, 0)
        XCTAssertEqual(outcome.text, longText)
        XCTAssertEqual(outcome.errorMessage, LLMCorrectionService.contextTooSmallMessage)
    }
}

// MARK: - Limits & Output Guard

@MainActor
final class LLMCorrectionServiceLimitTests: XCTestCase {

    private static let suiteName = "LLMCorrectionServiceLimitTests"
    private var defaults: UserDefaults!
    private var mockProvider: MockLLMProvider!
    private var sut: LLMCorrectionService!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        AppPreferences.store = defaults
        defaults.set(true, forKey: "llmCorrectionEnabled")
        mockProvider = MockLLMProvider()
        sut = LLMCorrectionService(
            providerFactory: { [mockProvider] in mockProvider! },
            timeoutForExpectedTokens: { _ in .milliseconds(200) }
        )
    }

    override func tearDown() async throws {
        sut = nil
        mockProvider = nil
        defaults.removePersistentDomain(forName: Self.suiteName)
        AppPreferences.store = .standard
        defaults = nil
        try await super.tearDown()
    }

    func testCorrect_ProviderIgnoringCancellation_StillReturnsAtTimeout() async {
        mockProvider.delay = .seconds(5)
        mockProvider.ignoresCancellation = true
        let start = ContinuousClock.now

        let outcome = await sut.correct("hello world")

        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertEqual(outcome.text, "hello world")
        XCTAssertEqual(outcome.errorMessage, LLMProviderError.timeout(seconds: 0).userFacingMessage)
    }

    func testCorrect_TaskCancelled_ReturnsOriginalWithoutMessage() async {
        sut = LLMCorrectionService(providerFactory: { [mockProvider] in mockProvider! })
        mockProvider.delay = .seconds(5)
        mockProvider.ignoresCancellation = true
        let start = ContinuousClock.now

        let task = Task { await self.sut.correct("hello world") }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let outcome = await task.value

        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertEqual(outcome.text, "hello world")
        XCTAssertNil(outcome.errorMessage)
    }

    func testCorrect_OutputGuardAppliesOnlyToTheDefaultPrompt() async {
        let text = String(repeating: "長い文章です。", count: 40)
        mockProvider.correctResult = "短い。"

        let guarded = await sut.correct(text)
        XCTAssertEqual(guarded.text, text)
        XCTAssertEqual(guarded.errorMessage, LLMCorrectionService.suspiciousOutputMessage)

        defaults.set(true, forKey: "useCustomCorrectionPrompt")
        defaults.set("Summarize the transcript.", forKey: "customCorrectionPrompt")
        let custom = await sut.correct(text)
        XCTAssertEqual(custom.text, "短い。")
        XCTAssertNil(custom.errorMessage)
    }

    func testLimitsNotice_ExplainsCapacityAndFlagsUnusableOrSmallSettings() {
        func notice(context: Int, output: Int, thinking: Bool = false) -> LLMCorrectionService.LimitsNotice {
            LLMCorrectionService.limitsNotice(
                options: LLMRequestOptions(
                    contextTokens: context, maxOutputTokens: output, thinkingEnabled: thinking, thinkingEffort: .medium
                ),
                userPrompt: LLMCorrectionService.defaultCorrectionPrompt
            )
        }

        let healthy = notice(context: 131_072, output: 32_768)
        XCTAssertEqual(healthy.level, .info)
        XCTAssertTrue(healthy.message.contains("per request"), healthy.message)

        XCTAssertEqual(notice(context: 8192, output: 8192).level, .error)
        XCTAssertEqual(notice(context: 1024, output: 512).level, .error)
        XCTAssertEqual(notice(context: 131_072, output: 1024).level, .warning)
        XCTAssertEqual(notice(context: 131_072, output: 12_000, thinking: true).level, .warning)
    }
}
