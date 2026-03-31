// LLMPreferencesMigrationTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class LLMPreferencesMigrationTests: XCTestCase {

    private let defaults = UserDefaults.standard

    override func setUp() async throws {
        try await super.setUp()
        for key in ["bedrockEnabled", "bedrockCorrectionPrompt",
                     "llmCorrectionEnabled", "llmProvider", "llmCorrectionPrompt",
                     "llmMigrationCompleted",
                     "openAIBaseURL", "openAIAPIKey", "openAIModel", "openAICustomHeaders"] {
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() async throws {
        for key in ["bedrockEnabled", "bedrockCorrectionPrompt",
                     "llmCorrectionEnabled", "llmProvider", "llmCorrectionPrompt",
                     "llmMigrationCompleted",
                     "openAIBaseURL", "openAIAPIKey", "openAIModel", "openAICustomHeaders"] {
            defaults.removeObject(forKey: key)
        }
        try await super.tearDown()
    }

    // MARK: - Migration Tests

    func testMigration_BedrockEnabledTrue_MigratesCorrectly() {
        defaults.set(true, forKey: "bedrockEnabled")

        AppPreferences.shared.migrateOldPreferences()

        XCTAssertTrue(defaults.bool(forKey: "llmCorrectionEnabled"))
        XCTAssertEqual(defaults.string(forKey: "llmProvider"), "bedrock")
        XCTAssertTrue(defaults.bool(forKey: "llmMigrationCompleted"))
    }

    func testMigration_BedrockEnabledFalse_MigratesCorrectly() {
        defaults.set(false, forKey: "bedrockEnabled")

        AppPreferences.shared.migrateOldPreferences()

        XCTAssertFalse(defaults.bool(forKey: "llmCorrectionEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "llmMigrationCompleted"))
    }

    func testMigration_CustomPrompt_Preserved() {
        defaults.set("My custom prompt", forKey: "bedrockCorrectionPrompt")

        AppPreferences.shared.migrateOldPreferences()

        XCTAssertEqual(defaults.string(forKey: "llmCorrectionPrompt"), "My custom prompt")
    }

    func testMigration_Idempotent() {
        defaults.set(true, forKey: "bedrockEnabled")

        AppPreferences.shared.migrateOldPreferences()

        defaults.set(false, forKey: "llmCorrectionEnabled")

        AppPreferences.shared.migrateOldPreferences()

        XCTAssertFalse(defaults.bool(forKey: "llmCorrectionEnabled"),
                        "Second migration should not overwrite existing value")
    }

    func testMigration_AlreadyMigrated_SkipsGracefully() {
        defaults.set(true, forKey: "llmCorrectionEnabled")
        defaults.set("openai", forKey: "llmProvider")

        AppPreferences.shared.migrateOldPreferences()

        XCTAssertTrue(defaults.bool(forKey: "llmCorrectionEnabled"))
        XCTAssertEqual(defaults.string(forKey: "llmProvider"), "openai",
                        "Migration should not overwrite existing llmProvider")
    }

    // MARK: - Default Values

    func testOpenAIDefaults() {
        XCTAssertEqual(AppPreferences.shared.openAIBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(AppPreferences.shared.openAIAPIKey, "")
        XCTAssertEqual(AppPreferences.shared.openAIModel, "gpt-4o-mini")
        XCTAssertEqual(AppPreferences.shared.openAICustomHeaders, "")
    }
}
