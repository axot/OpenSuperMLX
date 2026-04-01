// BedrockLLMProviderTests.swift
// OpenSuperMLXTests

import XCTest

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
}
