// PromptPresetTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class PromptPresetTests: XCTestCase {

    // MARK: - Shortcut Names

    func testShortcutNameIsStableForTheSameID() {
        let id = UUID()
        XCTAssertEqual(
            PromptPreset.shortcutName(for: id).rawValue,
            PromptPreset.shortcutName(for: id).rawValue
        )
        XCTAssertEqual(
            PromptPreset.shortcutName(for: id).rawValue,
            "promptPreset_\(id.uuidString)"
        )
    }

    func testShortcutNamesDifferAcrossPresets() {
        XCTAssertNotEqual(
            PromptPreset.shortcutName(for: UUID()).rawValue,
            PromptPreset.shortcutName(for: UUID()).rawValue
        )
    }

    // MARK: - Validation

    func testValidationRejectsEmptyName() {
        XCTAssertNotNil(PromptPresetValidation.errorMessage(name: "   ", instruction: "Fix grammar."))
    }

    func testValidationRejectsEmptyInstruction() {
        XCTAssertNotNil(PromptPresetValidation.errorMessage(name: "Polish", instruction: " \n "))
    }

    func testValidationRejectsOverlongName() {
        let name = String(repeating: "a", count: PromptPresetValidation.maxNameLength + 1)
        XCTAssertNotNil(PromptPresetValidation.errorMessage(name: name, instruction: "Fix grammar."))
    }

    func testValidationRejectsOverlongInstruction() {
        let instruction = String(repeating: "a", count: PromptPresetValidation.maxInstructionLength + 1)
        XCTAssertNotNil(PromptPresetValidation.errorMessage(name: "Polish", instruction: instruction))
    }

    func testValidationAcceptsValidPreset() {
        XCTAssertNil(PromptPresetValidation.errorMessage(name: "Polish", instruction: "Fix grammar."))
    }

    func testNormalizationTrimsWhitespace() {
        let normalized = PromptPresetValidation.normalized(
            name: "  Polish  ",
            instruction: "\n Fix grammar. \n"
        )
        XCTAssertEqual(normalized.name, "Polish")
        XCTAssertEqual(normalized.instruction, "Fix grammar.")
    }
}
