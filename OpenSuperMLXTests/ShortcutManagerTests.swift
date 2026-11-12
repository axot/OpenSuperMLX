// ShortcutManagerTests.swift
// OpenSuperMLXTests

import XCTest

import KeyboardShortcuts
@testable import OpenSuperMLX

final class ShortcutManagerTests: XCTestCase {
    func testIndicatorEscapeIsGlobalOutsideAnActiveInspector() {
        var state = EscapeShortcutState()
        XCTAssertFalse(state.shouldRegisterGlobalEscape)
        state.indicatorVisible = true
        state.inspectorVisible = true
        XCTAssertTrue(state.shouldRegisterGlobalEscape)
        state.applicationActive = true
        state.inspectorVisible = false
        XCTAssertTrue(state.shouldRegisterGlobalEscape)
    }

    func testActiveInspectorUnregistersGlobalEscape() {
        var state = EscapeShortcutState()
        state.indicatorVisible = true
        state.inspectorVisible = true
        state.applicationActive = true
        XCTAssertFalse(state.shouldRegisterGlobalEscape)
    }

    func testClosingInspectorDoesNotTransferEscapeBeforeKeyRelease() {
        var state = EscapeShortcutState()
        state.indicatorVisible = true
        state.inspectorVisible = true
        state.applicationActive = true
        state.escapeIsDown = true
        state.inspectorVisible = false
        XCTAssertFalse(state.shouldRegisterGlobalEscape)
        state.escapeIsDown = false
        XCTAssertTrue(state.shouldRegisterGlobalEscape)
    }
}

// MARK: - Voice Command Capture

final class CommandCaptureGateTests: XCTestCase {
    func testCaptureProceedsWhenNothingInterrupts() {
        var gate = CommandCaptureGate()

        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.finish())
    }

    func testStopDuringCaptureAbandonsTheCommand() {
        var gate = CommandCaptureGate()
        XCTAssertTrue(gate.begin())

        XCTAssertTrue(gate.requestStop())

        XCTAssertFalse(gate.finish())
        XCTAssertTrue(gate.begin(), "A later press starts a fresh capture")
    }

    func testOnlyOneCaptureRunsAtATime() {
        var gate = CommandCaptureGate()
        XCTAssertTrue(gate.begin())

        XCTAssertFalse(gate.begin())
        var idle = CommandCaptureGate()
        XCTAssertFalse(idle.requestStop(), "No capture, nothing to stop")
    }
}

// MARK: - Built-in Shortcut Conflicts

@MainActor
final class BuiltInShortcutConflictTests: XCTestCase {
    private let f17 = KeyboardShortcuts.Shortcut(.f17)
    private let f19 = KeyboardShortcuts.Shortcut(.f19)

    func testShortcutUsedByAnotherBuiltInIsReported() {
        let assigned: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [.toggleRecord: f19, .voiceCommand: f17]

        let owner = ShortcutManager.builtInShortcutOwner(of: f19, excluding: .voiceCommand) { assigned[$0] }

        XCTAssertEqual(owner, "Toggle record")
    }

    func testReassigningTheSameShortcutIsAllowed() {
        let assigned: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [.toggleRecord: f19, .voiceCommand: f17]

        XCTAssertNil(ShortcutManager.builtInShortcutOwner(of: f17, excluding: .voiceCommand) { assigned[$0] })
        XCTAssertNil(ShortcutManager.builtInShortcutOwner(of: KeyboardShortcuts.Shortcut(.f16), excluding: nil) { assigned[$0] })
    }

    func testPresetShortcutCannotTakeABuiltIn() {
        let assigned: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [.toggleRecord: f19, .voiceCommand: f17]

        XCTAssertEqual(
            ShortcutManager.builtInShortcutOwner(of: f17, excluding: nil) { assigned[$0] },
            "Voice command on selection"
        )
    }
}
