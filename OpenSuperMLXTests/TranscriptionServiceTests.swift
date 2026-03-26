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
    }

    // MARK: - Error Handling

    func testTranscribe_EngineThrows_PropagatesError() async {
        mockEngine.shouldThrow = TranscriptionError.processingFailed

        do {
            _ = try await sut.transcribeAudio(
                url: dummyURL, settings: Settings(), applyCorrection: false
            )
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is TranscriptionError)
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

        mockEngine.resumeTranscription()
        _ = try? await task.value
    }
}
