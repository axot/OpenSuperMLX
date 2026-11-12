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

    // MARK: - Retired Settings

    func testMigrationRemovesRetiredRecordWithLLMShortcut() {
        defaults.set("{\"carbonKeyCode\":79,\"carbonModifiers\":0}", forKey: "KeyboardShortcuts_toggleRecordWithLLM")

        AppPreferences.migrateOldPreferences(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "KeyboardShortcuts_toggleRecordWithLLM"))
    }

    // MARK: - Neural Engine Audio Tower

    func testNeuralEngineAudioTowerIsOnByDefault() {
        XCTAssertTrue(AppPreferences.shared.useNeuralEngineAudioTower)
    }

    // MARK: - Prompt Presets

    func testPresetsAlwaysReplaceIsOnByDefault() {
        XCTAssertTrue(AppPreferences.shared.presetsAlwaysReplace)
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
