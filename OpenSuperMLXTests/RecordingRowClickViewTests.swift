// RecordingRowClickViewTests.swift
// OpenSuperMLXTests

import AppKit
import XCTest

@testable import OpenSuperMLX

@MainActor
final class RecordingRowClickViewTests: XCTestCase {
    func testFirstMouseIsAcceptedWithoutActivatingTheWindowFirst() {
        let button = RecordingRowClickButton()
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
    }

    func testSinglePressInvokesSelectionExactlyOnce() {
        let button = RecordingRowClickButton()
        var selections = 0
        button.onSelect = { selections += 1 }
        button.performClick(nil)
        XCTAssertEqual(selections, 1)
    }

    func testUpdatedActionDoesNotInvokeOldSelection() {
        let button = RecordingRowClickButton()
        var oldSelections = 0
        var newSelections = 0
        button.onSelect = { oldSelections += 1 }
        button.onSelect = { newSelections += 1 }
        button.performClick(nil)
        XCTAssertEqual(oldSelections, 0)
        XCTAssertEqual(newSelections, 1)
    }
}
