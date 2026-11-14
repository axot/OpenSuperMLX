// TranscriptionServiceTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

@MainActor
final class TranscriptionServiceTests: XCTestCase {
    private var mockEngine: MockTranscriptionEngine!
    private var sut: TranscriptionService!
    private let dummyURL = URL(fileURLWithPath: "/dev/null")

    override func setUp() async throws {
        try await super.setUp()
        mockEngine = MockTranscriptionEngine()
        sut = TranscriptionService(engine: mockEngine)
    }

    override func tearDown() async throws {
        sut = nil
        mockEngine = nil
        try await super.tearDown()
    }

    // MARK: - Happy Path

    func testTranscribe_HappyPath() async throws {
        mockEngine.transcribeResult = "hello world"

        let result = try await sut.transcribeAudio(
            url: dummyURL, settings: Settings(), applyCorrection: false
        )

        XCTAssertEqual(result, "hello world")
        XCTAssertEqual(mockEngine.transcribeCallCount, 1)
        XCTAssertEqual(sut.transcribedText, "hello world")
        XCTAssertEqual(sut.progress, 1.0, accuracy: 0.01)
        XCTAssertFalse(sut.isTranscribing)
    }

    func testTranscribe_AppliesCleanupPresetWhenCorrecting() async throws {
        let suite = "TranscriptionServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        AppPreferences.store = defaults
        defer {
            AppPreferences.store = .standard
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(true, forKey: "llmCorrectionEnabled")
        let provider = MockLLMProvider()
        provider.correctResult = "Hi Dana, the demo moved to Friday."
        let service = TranscriptionService(
            engine: mockEngine,
            corrector: LLMCorrectionService(providerFactory: { provider })
        )
        mockEngine.transcribeResult = "tell dana the demo moved to friday"
        let email = PromptPreset(name: "Email", instruction: "Write an email body.")

        let result = try await service.transcribeAudio(url: dummyURL, settings: Settings(), cleanupPreset: email)

        XCTAssertEqual(result, "Hi Dana, the demo moved to Friday.")
        XCTAssertTrue(provider.lastSystemPrompt?.contains("Write an email body.") == true)
    }

    // MARK: - Error Handling

    func testTranscribe_EngineThrows_PropagatesError() async {
        mockEngine.shouldThrow = TranscriptionError.processingFailed

        do {
            _ = try await sut.transcribeAudio(
                url: dummyURL, settings: Settings(), applyCorrection: false
            )
            XCTFail("Expected error to be thrown")
        } catch let error as TranscriptionError {
            if case .processingFailed = error {} else {
                XCTFail("Expected .processingFailed, got \(error)")
            }
        } catch {
            XCTFail("Expected TranscriptionError.processingFailed, got \(error)")
        }
    }

    func testTranscribe_ThrowsContextInitFailed_WhenNoEngine() async {
        let serviceWithoutEngine = TranscriptionService(engine: nil)

        do {
            _ = try await serviceWithoutEngine.transcribeAudio(
                url: dummyURL, settings: Settings(), applyCorrection: false
            )
            XCTFail("Expected contextInitializationFailed")
        } catch let error as TranscriptionError {
            XCTAssertEqual(
                error.errorDescription,
                TranscriptionError.contextInitializationFailed.errorDescription
            )
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - State Management

    func testTranscribe_SetsIsTranscribingDuringTranscription() async throws {
        mockEngine.shouldSuspend = true
        XCTAssertFalse(sut.isTranscribing)

        let task = Task { @MainActor in
            try await sut.transcribeAudio(
                url: dummyURL, settings: Settings(), applyCorrection: false
            )
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(sut.isTranscribing)

        mockEngine.resumeTranscription()
        _ = try? await task.value
        XCTAssertFalse(sut.isTranscribing)
    }

    func testTranscribe_SetsProgressToOneOnCompletion() async throws {
        XCTAssertEqual(sut.progress, 0.0)

        _ = try await sut.transcribeAudio(
            url: dummyURL, settings: Settings(), applyCorrection: false
        )

        XCTAssertEqual(sut.progress, 1.0)
    }

    // MARK: - Cancellation

    func testTranscribe_CancellationStopsTranscription() async throws {
        mockEngine.shouldSuspend = true

        let task = Task { @MainActor in
            try await sut.transcribeAudio(
                url: dummyURL, settings: Settings(), applyCorrection: false
            )
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(sut.isTranscribing)

        sut.cancelTranscription()
        XCTAssertFalse(sut.isTranscribing)
        XCTAssertEqual(mockEngine.cancelCallCount, 1, "cancelTranscription should propagate to engine")

        mockEngine.resumeTranscription()
        _ = try? await task.value
    }
}
