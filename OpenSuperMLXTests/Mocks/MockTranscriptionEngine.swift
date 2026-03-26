// MockTranscriptionEngine.swift
// OpenSuperMLXTests

import Foundation

@testable import OpenSuperMLX

final class MockTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    var engineName = "Mock"
    var isModelLoaded = true
    var transcribeResult = "mock transcription"
    var shouldThrow: Error?
    var transcribeCallCount = 0
    var shouldSuspend = false
    private var continuation: CheckedContinuation<Void, Never>?

    func initialize() async throws {}

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        transcribeCallCount += 1
        if shouldSuspend {
            await withCheckedContinuation { self.continuation = $0 }
        }
        if let error = shouldThrow { throw error }
        return transcribeResult
    }

    func cancelTranscription() {}

    func resumeTranscription() {
        continuation?.resume()
        continuation = nil
    }

    func getSupportedLanguages() -> [String] {
        ["en", "zh", "ja"]
    }
}
