// ShortcutManagerTests.swift
// OpenSuperMLXTests

import XCTest

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
