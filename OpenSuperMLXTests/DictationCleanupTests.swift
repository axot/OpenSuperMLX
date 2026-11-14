// DictationCleanupTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

@MainActor
final class DictationCleanupTests: XCTestCase {

    private static let suiteName = "DictationCleanupTests"
    private var defaults: UserDefaults!
    private let email = PromptPreset(name: "Email", instruction: "Write an email.")
    private let bullets = PromptPreset(name: "Bullet points", instruction: "Make bullets.")

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        AppPreferences.store = defaults
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: Self.suiteName)
        AppPreferences.store = .standard
        defaults = nil
        try await super.tearDown()
    }

    // MARK: - Resolving

    func testCorrectionOffResolvesToRaw() {
        AppPreferences.shared.llmCorrectionEnabled = false
        AppPreferences.shared.dictationCleanupPresetID = email.id.uuidString

        XCTAssertEqual(DictationCleanup.current(presets: [email]), .raw)
    }

    func testCorrectionOnWithoutPresetResolvesToClean() {
        AppPreferences.shared.llmCorrectionEnabled = true

        XCTAssertEqual(DictationCleanup.current(presets: [email]), .clean)
    }

    func testStoredPresetResolvesToThatPreset() {
        AppPreferences.shared.llmCorrectionEnabled = true
        AppPreferences.shared.dictationCleanupPresetID = bullets.id.uuidString

        let current = DictationCleanup.current(presets: [email, bullets])

        XCTAssertEqual(current, .preset(bullets))
        XCTAssertEqual(current.preset, bullets)
        XCTAssertEqual(current.title, "Bullet points")
    }

    func testDeletedPresetFallsBackToClean() {
        AppPreferences.shared.llmCorrectionEnabled = true
        AppPreferences.shared.dictationCleanupPresetID = UUID().uuidString

        XCTAssertEqual(DictationCleanup.current(presets: [email]), .clean)
    }

    // MARK: - Selecting

    func testSelectingKeepsCorrectionToggleInSync() {
        DictationCleanup.preset(email).select()
        XCTAssertTrue(AppPreferences.shared.llmCorrectionEnabled)
        XCTAssertEqual(DictationCleanup.current(presets: [email]), .preset(email))

        DictationCleanup.raw.select()
        XCTAssertFalse(AppPreferences.shared.llmCorrectionEnabled)
        XCTAssertEqual(DictationCleanup.current(presets: [email]), .raw)

        DictationCleanup.clean.select()
        XCTAssertTrue(AppPreferences.shared.llmCorrectionEnabled)
        XCTAssertNil(AppPreferences.shared.dictationCleanupPresetID)
        XCTAssertEqual(DictationCleanup.current(presets: [email]), .clean)
    }

    func testSelectingAnnouncesTheChangeSoOpenSettingsRefresh() {
        let posted = expectation(forNotification: .dictationCleanupDidChange, object: nil)

        DictationCleanup.raw.select()

        wait(for: [posted], timeout: 0.1)
    }

    func testChoicesListRawAndCleanBeforePresetsInOrder() {
        XCTAssertEqual(
            DictationCleanup.choices(presets: [email, bullets]),
            [.raw, .clean, .preset(email), .preset(bullets)]
        )
    }
}
