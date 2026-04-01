// LLMPreferencesMigrationTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class LLMPreferencesMigrationTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LLMPreferencesMigrationTests")!
        defaults.removePersistentDomain(forName: "LLMPreferencesMigrationTests")
        AppPreferences.store = defaults
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "LLMPreferencesMigrationTests")
        AppPreferences.store = .standard
        defaults = nil
        super.tearDown()
    }

    // MARK: - Migration Tests

    func testMigration_BedrockEnabledTrue_MigratesCorrectly() {
        defaults.set(true, forKey: "bedrockEnabled")

        AppPreferences.migrateOldPreferences(defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: "llmCorrectionEnabled"))
        XCTAssertEqual(defaults.string(forKey: "llmProvider"), "bedrock")
        XCTAssertTrue(defaults.bool(forKey: "llmMigrationCompleted"))
    }

    func testMigration_BedrockEnabledFalse_MigratesCorrectly() {
        defaults.set(false, forKey: "bedrockEnabled")

        AppPreferences.migrateOldPreferences(defaults: defaults)

        XCTAssertFalse(defaults.bool(forKey: "llmCorrectionEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "llmMigrationCompleted"))
    }

    func testMigration_CustomPrompt_MigratedToCustomMode() {
        defaults.set("My custom prompt", forKey: "bedrockCorrectionPrompt")

        AppPreferences.migrateOldPreferences(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "customCorrectionPrompt"), "My custom prompt")
        XCTAssertTrue(defaults.bool(forKey: "useCustomCorrectionPrompt"))
        XCTAssertNil(defaults.object(forKey: "bedrockCorrectionPrompt"))
    }

    func testMigration_DefaultPrompt_NotMigratedToCustom() {
        defaults.set(LLMCorrectionService.defaultCorrectionPrompt, forKey: "bedrockCorrectionPrompt")

        AppPreferences.migrateOldPreferences(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "customCorrectionPrompt"))
        XCTAssertFalse(defaults.bool(forKey: "useCustomCorrectionPrompt"))
        XCTAssertNil(defaults.object(forKey: "bedrockCorrectionPrompt"))
    }

    func testMigration_Idempotent() {
        defaults.set(true, forKey: "bedrockEnabled")

        AppPreferences.migrateOldPreferences(defaults: defaults)

        defaults.set(false, forKey: "llmCorrectionEnabled")

        AppPreferences.migrateOldPreferences(defaults: defaults)

        XCTAssertFalse(defaults.bool(forKey: "llmCorrectionEnabled"),
                        "Second migration should not overwrite existing value")
    }

    func testMigration_AlreadyMigrated_SkipsGracefully() {
        defaults.set(true, forKey: "llmCorrectionEnabled")
        defaults.set("openai", forKey: "llmProvider")
        defaults.set(true, forKey: "llmMigrationCompleted")

        AppPreferences.migrateOldPreferences(defaults: defaults)

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
