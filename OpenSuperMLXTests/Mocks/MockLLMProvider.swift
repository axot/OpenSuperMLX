// MockLLMProvider.swift
// OpenSuperMLXTests

import Foundation

@testable import OpenSuperMLX

final class MockLLMProvider: LLMProvider, @unchecked Sendable {
    var displayName = "Mock"
    var isConfigured = true
    var correctResult = "corrected text"
    var shouldThrowError: Error?
    var correctCallCount = 0
    var lastText: String?
    var lastSystemPrompt: String?

    func correctTranscription(_ text: String, systemPrompt: String) async throws -> String {
        correctCallCount += 1
        lastText = text
        lastSystemPrompt = systemPrompt
        if let error = shouldThrowError { throw error }
        return correctResult
    }
}
