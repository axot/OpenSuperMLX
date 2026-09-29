// AppPreferencesTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class AppPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AppPreferencesTests")!
        defaults.removePersistentDomain(forName: "AppPreferencesTests")
        AppPreferences.store = defaults
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "AppPreferencesTests")
        AppPreferences.store = .standard
        defaults = nil
        super.tearDown()
    }

    // MARK: - migrateCorrectionPrompt

    func testMigration_OldKeyWithCustomValue_MigratedToNewKey() {
        let customPrompt = "My custom prompt"
        defaults.set(customPrompt, forKey: "bedrockCorrectionPrompt")

        AppPreferences.migrateCorrectionPrompt(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "customCorrectionPrompt"), customPrompt)
        XCTAssertTrue(defaults.bool(forKey: "useCustomCorrectionPrompt"))
        XCTAssertNil(defaults.object(forKey: "bedrockCorrectionPrompt"))
    }

    func testMigration_OldKeyWithDefaultValue_RemovedWithoutMigrating() {
        defaults.set(LLMCorrectionService.defaultCorrectionPrompt, forKey: "bedrockCorrectionPrompt")

        AppPreferences.migrateCorrectionPrompt(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "customCorrectionPrompt"))
        XCTAssertFalse(defaults.bool(forKey: "useCustomCorrectionPrompt"))
        XCTAssertNil(defaults.object(forKey: "bedrockCorrectionPrompt"))
    }

    func testMigration_NoOldKey_NothingHappens() {
        AppPreferences.migrateCorrectionPrompt(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "customCorrectionPrompt"))
        XCTAssertFalse(defaults.bool(forKey: "useCustomCorrectionPrompt"))
        XCTAssertNil(defaults.object(forKey: "bedrockCorrectionPrompt"))
    }

    // MARK: - effectiveCorrectionPrompt

    func testEffectivePrompt_DefaultMode_ReturnsDefault() {
        let prefs = AppPreferences.shared
        prefs.useCustomCorrectionPrompt = false
        prefs.customCorrectionPrompt = "Some saved custom text"

        XCTAssertEqual(prefs.effectiveCorrectionPrompt, LLMCorrectionService.defaultCorrectionPrompt)
    }

    func testEffectivePrompt_CustomMode_ReturnsCustom() {
        let prefs = AppPreferences.shared
        let custom = "Custom correction prompt for test"
        prefs.useCustomCorrectionPrompt = true
        prefs.customCorrectionPrompt = custom

        XCTAssertEqual(prefs.effectiveCorrectionPrompt, custom)
    }

    func testEffectivePrompt_CustomModeEmptyText_FallsBackToDefault() {
        let prefs = AppPreferences.shared
        prefs.useCustomCorrectionPrompt = true
        prefs.customCorrectionPrompt = ""

        XCTAssertEqual(prefs.effectiveCorrectionPrompt, LLMCorrectionService.defaultCorrectionPrompt)
    }
}

// MARK: - LLM Request Settings

final class AppPreferencesLLMRequestTests: XCTestCase {
    private static let suiteName = "AppPreferencesLLMRequestTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        AppPreferences.store = defaults
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        AppPreferences.store = .standard
        defaults = nil
        super.tearDown()
    }

    func testDefaults_ArePrefilledPerProvider() {
        let prefs = AppPreferences.shared
        XCTAssertTrue(prefs.openAIThinkingEnabled)
        XCTAssertEqual(prefs.openAIThinkingEffort, "medium")
        XCTAssertEqual(prefs.openAIContextTokens, 131_072)
        XCTAssertEqual(prefs.openAIMaxOutputTokens, 16_384)
        XCTAssertEqual(prefs.openAIExtraBody, "")
        XCTAssertFalse(prefs.bedrockThinkingEnabled)
        XCTAssertEqual(prefs.bedrockThinkingEffort, "medium")
        XCTAssertEqual(prefs.bedrockContextTokens, 200_000)
        XCTAssertEqual(prefs.bedrockMaxOutputTokens, 4096)
    }

    func testMigration_ExistingOpenAIConfig_KeepsLegacyOutputLimit() {
        defaults.set("gpt-4o-mini", forKey: "openAIModel")

        AppPreferences.migrateLLMOutputLimit(defaults: defaults)

        XCTAssertEqual(defaults.integer(forKey: "openAIMaxOutputTokens"), 4096)
    }

    func testMigration_FreshInstallOrExplicitValue_LeftUntouched() {
        AppPreferences.migrateLLMOutputLimit(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "openAIMaxOutputTokens"))

        defaults.set("gpt-6-luna", forKey: "openAIModel")
        defaults.set(32_768, forKey: "openAIMaxOutputTokens")
        AppPreferences.migrateLLMOutputLimit(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: "openAIMaxOutputTokens"), 32_768)
    }
}
