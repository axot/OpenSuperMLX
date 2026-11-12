// PromptPresetStoreTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

@MainActor
final class PromptPresetStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: PromptPresetStore!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "PromptPresetStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = PromptPresetStore(defaults: defaults, seedExamples: false)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testAddAppendsNormalizedPreset() {
        let preset = store.add(name: "  Polish  ", instruction: " Fix grammar. ")

        XCTAssertNotNil(preset)
        XCTAssertEqual(preset?.name, "Polish")
        XCTAssertEqual(preset?.instruction, "Fix grammar.")
        XCTAssertEqual(store.presets.count, 1)
    }

    func testAddRejectsInvalidInput() {
        XCTAssertNil(store.add(name: "", instruction: "Fix grammar."))
        XCTAssertNil(store.add(name: "Polish", instruction: ""))
        XCTAssertTrue(store.presets.isEmpty)
    }

    func testUpdateChangesNameAndInstruction() {
        let preset = store.add(name: "Polish", instruction: "Fix grammar.")!

        let updated = store.update(id: preset.id, name: "Tighten", instruction: "Shorten it.")

        XCTAssertTrue(updated)
        XCTAssertEqual(store.presets.first?.name, "Tighten")
        XCTAssertEqual(store.presets.first?.instruction, "Shorten it.")
    }

    func testUpdateUnknownIDReturnsFalse() {
        XCTAssertFalse(store.update(id: UUID(), name: "Polish", instruction: "Fix grammar."))
    }

    func testDeleteRemovesPreset() {
        let preset = store.add(name: "Polish", instruction: "Fix grammar.")!

        store.delete(id: preset.id)

        XCTAssertTrue(store.presets.isEmpty)
    }

    func testPresetsPersistAcrossStoreInstances() {
        store.add(name: "Polish", instruction: "Fix grammar.")
        store.add(name: "Tighten", instruction: "Shorten it.")

        let reloaded = PromptPresetStore(defaults: defaults, seedExamples: false)

        XCTAssertEqual(reloaded.presets, store.presets)
    }

    func testMutationPostsChangeNotification() {
        let expectation = expectation(forNotification: .promptPresetsDidChange, object: nil)

        store.add(name: "Polish", instruction: "Fix grammar.")

        wait(for: [expectation], timeout: 1)
    }

    // MARK: - Example Presets

    func testSeedsExamplePresetsOnFirstLaunch() {
        let seeded = PromptPresetStore(defaults: defaults)

        XCTAssertEqual(
            seeded.presets.map(\.name),
            PromptPresetStore.examplePresets.map(\.name)
        )
        XCTAssertNotNil(
            seeded.presets.first(where: { $0.name == "Bullet points" })
        )
    }

    func testSeedingIsIdempotentAndKeepsUserEdits() {
        store.add(name: "Tighten", instruction: "My own tightening instructions.")

        _ = PromptPresetStore(defaults: defaults)
        let second = PromptPresetStore(defaults: defaults)

        XCTAssertEqual(second.presets.count, PromptPresetStore.examplePresets.count)
        XCTAssertEqual(Set(second.presets.map(\.name)).count, second.presets.count)
        XCTAssertEqual(
            second.presets.first(where: { $0.name == "Tighten" })?.instruction,
            "My own tightening instructions."
        )
    }
}

// MARK: - Retired Correction Prompt

@MainActor
final class PromptPresetStoreMigrationTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "PromptPresetStoreMigrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    func testActiveCustomPromptBecomesTheSelectedPreset() {
        defaults.set(true, forKey: "llmCorrectionEnabled")
        defaults.set(true, forKey: "useCustomCorrectionPrompt")
        defaults.set("Fix spelling only.", forKey: "customCorrectionPrompt")

        let store = PromptPresetStore(defaults: defaults, seedExamples: false)

        let migrated = store.presets.first { $0.name == PromptPresetStore.migratedPromptName }
        XCTAssertEqual(migrated?.instruction, "Fix spelling only.")
        XCTAssertEqual(defaults.string(forKey: "dictationCleanupPresetID"), migrated?.id.uuidString)
        XCTAssertNil(defaults.object(forKey: "useCustomCorrectionPrompt"))
        XCTAssertNil(defaults.object(forKey: "customCorrectionPrompt"))
    }

    func testLegacyBedrockPromptBecomesAPresetWithoutOverridingAChosenPreset() {
        defaults.set(true, forKey: "llmCorrectionEnabled")
        defaults.set("chosen-id", forKey: "dictationCleanupPresetID")
        defaults.set("Old Bedrock prompt.", forKey: "bedrockCorrectionPrompt")

        let store = PromptPresetStore(defaults: defaults, seedExamples: false)

        XCTAssertEqual(store.presets.map(\.instruction), ["Old Bedrock prompt."])
        XCTAssertEqual(defaults.string(forKey: "dictationCleanupPresetID"), "chosen-id")
        XCTAssertNil(defaults.object(forKey: "bedrockCorrectionPrompt"))
    }

    func testMigrationDoesNotPostChangeNotificationDuringInit() async {
        defaults.set(true, forKey: "useCustomCorrectionPrompt")
        defaults.set("Fix spelling only.", forKey: "customCorrectionPrompt")
        let posted = expectation(forNotification: .promptPresetsDidChange, object: nil)
        posted.isInverted = true

        let store = PromptPresetStore(defaults: defaults, seedExamples: false)

        await fulfillment(of: [posted], timeout: 0.1)
        XCTAssertEqual(store.presets.count, 1)
    }

    func testInactiveOrDefaultPromptIsDroppedWithoutAPreset() {
        defaults.set(false, forKey: "useCustomCorrectionPrompt")
        defaults.set("Unused draft.", forKey: "customCorrectionPrompt")
        defaults.set(LLMCorrectionService.defaultCorrectionPrompt, forKey: "bedrockCorrectionPrompt")

        let store = PromptPresetStore(defaults: defaults, seedExamples: false)

        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertNil(defaults.object(forKey: "customCorrectionPrompt"))
        XCTAssertNil(defaults.object(forKey: "bedrockCorrectionPrompt"))
    }
}
