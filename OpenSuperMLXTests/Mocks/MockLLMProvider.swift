// MockLLMProvider.swift
// OpenSuperMLXTests

import Foundation

@testable import OpenSuperMLX

final class MockLLMProvider: LLMProvider, @unchecked Sendable {
    var displayName = "Mock"
    var isConfigured = true
    var requestOptions = LLMRequestOptions(
        contextTokens: 131_072, maxOutputTokens: 32_768, thinkingEnabled: false, thinkingEffort: .medium
    )
    var correctResult = "corrected text"
    var shouldThrowError: Error?
    /// Per-call behavior: receives (text, systemPrompt, zero-based call index).
    var handler: ((String, String, Int) throws -> String)?
    var delay: Duration?
    /// Simulates SDK calls that keep running after their task is cancelled.
    var ignoresCancellation = false

    private let lock = NSLock()
    private var recordedCalls: [(text: String, systemPrompt: String)] = []

    var calls: [(text: String, systemPrompt: String)] { lock.withLock { recordedCalls } }
    var correctCallCount: Int { calls.count }
    var lastText: String? { calls.last?.text }
    var lastSystemPrompt: String? { calls.last?.systemPrompt }

    func correctTranscription(_ text: String, systemPrompt: String) async throws -> String {
        let index = lock.withLock {
            recordedCalls.append((text, systemPrompt))
            return recordedCalls.count - 1
        }
        if let delay {
            if ignoresCancellation {
                await Task.detached { try? await Task.sleep(for: delay) }.value
            } else {
                try await Task.sleep(for: delay)
            }
        }
        if let handler { return try handler(text, systemPrompt, index) }
        if let error = shouldThrowError { throw error }
        return correctResult
    }
}
