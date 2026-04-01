// OpenAICompatibleLLMProviderTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class OpenAICompatibleLLMProviderTests: XCTestCase {

    private static let suiteName = "OpenAICompatibleLLMProviderTests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        AppPreferences.store = defaults
        defaults.set("https://api.openai.com/v1", forKey: "openAIBaseURL")
        defaults.set("test-key", forKey: "openAIAPIKey")
        defaults.set("gpt-4o-mini", forKey: "openAIModel")
        defaults.set("", forKey: "openAICustomHeaders")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: Self.suiteName)
        AppPreferences.store = .standard
        defaults = nil
        try await super.tearDown()
    }

    // MARK: - Display Name

    func testDisplayName_ReturnsOpenAICompatible() {
        let provider = OpenAICompatibleLLMProvider()
        XCTAssertEqual(provider.displayName, "OpenAI Compatible")
    }

    // MARK: - isConfigured

    func testIsConfigured_ValidBaseURLAndModel_ReturnsTrue() {
        let provider = OpenAICompatibleLLMProvider()
        XCTAssertTrue(provider.isConfigured)
    }

    func testIsConfigured_EmptyBaseURL_ReturnsFalse() {
        defaults.set("", forKey: "openAIBaseURL")
        let provider = OpenAICompatibleLLMProvider()
        XCTAssertFalse(provider.isConfigured)
    }

    func testIsConfigured_InvalidBaseURL_ReturnsFalse() {
        defaults.set("not a url", forKey: "openAIBaseURL")
        let provider = OpenAICompatibleLLMProvider()
        XCTAssertFalse(provider.isConfigured)
    }

    func testIsConfigured_EmptyModel_ReturnsFalse() {
        defaults.set("", forKey: "openAIModel")
        let provider = OpenAICompatibleLLMProvider()
        XCTAssertFalse(provider.isConfigured)
    }

    func testIsConfigured_NoAPIKey_StillReturnsTrue() {
        defaults.set("", forKey: "openAIAPIKey")
        let provider = OpenAICompatibleLLMProvider()
        XCTAssertTrue(provider.isConfigured)
    }
}
