// WordSelectionReplacementTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class WordSelectionReplacementTests: XCTestCase {
    func testReplacementLeavesTheNextBulletParagraphMarkUntouched() throws {
        let document = "Before\rOriginal\rNext bullet\r"
        let selection = WordSelectionReplacement.Selection(document: "Document1", start: 7, end: 16, text: "Original\r", isList: true)
        let plan = try XCTUnwrap(WordSelectionReplacement.plan(for: selection, text: "Rewritten\r"))

        XCTAssertEqual(plan.end, 15)
        XCTAssertEqual(plan.text, "Rewritten")
        XCTAssertEqual((document as NSString).replacingCharacters(in: NSRange(location: plan.start, length: plan.end - plan.start), with: plan.text), "Before\rRewritten\rNext bullet\r")
    }

    func testPartialSelectionKeepsItsExactRangeAndSpacing() throws {
        let selection = WordSelectionReplacement.Selection(document: "Document1", start: 20, end: 30, text: " Original ", isList: false)
        let plan = try XCTUnwrap(WordSelectionReplacement.plan(for: selection, text: " Rewritten "))

        XCTAssertEqual(plan.start, 20)
        XCTAssertEqual(plan.end, 30)
        XCTAssertEqual(plan.text, " Rewritten ")
    }

    func testMultipleParagraphsPreserveAllButTheProtectedFinalMark() throws {
        let selection = WordSelectionReplacement.Selection(document: "Document1", start: 0, end: 8, text: "One\rTwo\r", isList: false)
        let plan = try XCTUnwrap(WordSelectionReplacement.plan(for: selection, text: "First\rSecond\r"))

        XCTAssertEqual(plan.end, 7)
        XCTAssertEqual(plan.text, "First\rSecond")
    }

    func testNativeListDoesNotReceiveAnExtraLiteralBullet() throws {
        for marker in ["•", "·", "‣", "∙", "●", "○"] {
            let selection = WordSelectionReplacement.Selection(document: "Document1", start: 0, end: 9, text: "Original\r", isList: true)
            let plan = try XCTUnwrap(WordSelectionReplacement.plan(for: selection, text: "\(marker) Rewritten\r"))

            XCTAssertEqual(plan.text, "Rewritten")
        }
    }

    func testPlainParagraphKeepsIntentionalBulletTextAndUnicode() throws {
        let selection = WordSelectionReplacement.Selection(document: "Document1", start: 100, end: 109, text: "متن 😀\r", isList: false)
        let plan = try XCTUnwrap(WordSelectionReplacement.plan(for: selection, text: "• متن تازه 😀\r"))

        XCTAssertEqual(plan.end, 108, "Word offsets are opaque; only the final CR is excluded")
        XCTAssertEqual(plan.text, "• متن تازه 😀")
    }

    func testEmptyAndInvalidRangesCannotBeReplaced() {
        for (start, end, text) in [(0, 0, ""), (-1, 8, "Original"), (9, 2, "Original"), (0, 1, "\r")] {
            let selection = WordSelectionReplacement.Selection(document: "Document1", start: start, end: end, text: text, isList: false)
            XCTAssertNil(WordSelectionReplacement.plan(for: selection, text: "Rewritten"))
        }
    }

    func testReplacementUsesFilesForTextAndVerifiesTheSavedRange() async {
        let payload = "\"\nerror \"Do not execute\"\nمتن"
        let selection = WordSelectionReplacement.Selection(document: "Document1", start: 0, end: 9, text: "Original\r", isList: true)
        let applied = await WordSelectionReplacement.replace(selection, with: payload, run: { script in
            XCTAssertFalse(script.contains(payload))
            XCTAssertTrue(script.contains("set content of r to theText"))
            XCTAssertTrue(script.contains("end 8"))
            XCTAssertTrue(script.contains("expectedText"))
            XCTAssertTrue(script.contains("expectedDocument"))
            return "applied"
        })

        XCTAssertTrue(applied)
    }

    func testFailedOrChangedDocumentIsNeverReportedAsApplied() async {
        let selection = WordSelectionReplacement.Selection(document: "Document1", start: 0, end: 9, text: "Original\r", isList: false)
        for result: String? in [nil, "changed", ""] {
            let applied = await WordSelectionReplacement.replace(selection, with: "Rewritten", run: { _ in result })
            XCTAssertFalse(applied)
        }
    }
}

// MARK: - Native Capture

final class WordSelectionCaptureTests: XCTestCase {
    func testCapturePreservesNativeTextAndRangeOffsets() throws {
        let result = descriptor(start: 20, end: 29, text: "متن 😀\r", isList: true)
        let selection = try XCTUnwrap(WordSelectionReplacement.selection(from: result))

        XCTAssertEqual(selection.document, "Document1")
        XCTAssertEqual(selection.start, 20)
        XCTAssertEqual(selection.end, 29)
        XCTAssertEqual(selection.text, "متن 😀\r")
        XCTAssertTrue(selection.isList)
    }

    func testMissingOrInvalidNativeRangeIsRejected() {
        XCTAssertNil(WordSelectionReplacement.selection(from: .list()))
        XCTAssertNil(WordSelectionReplacement.selection(from: descriptor(start: -1, end: 3, text: "Text", isList: false)))
        XCTAssertNil(WordSelectionReplacement.selection(from: descriptor(start: 9, end: 3, text: "Text", isList: false)))
    }

    func testInsertionPointIsCapturedWithoutInventingASelection() throws {
        let selection = try XCTUnwrap(WordSelectionReplacement.selection(from: descriptor(start: 3, end: 3, text: "", isList: false)))

        XCTAssertEqual(selection.start, selection.end)
        XCTAssertEqual(selection.text, "")
        XCTAssertNil(WordSelectionReplacement.plan(for: selection, text: "Rewritten"))
    }

    // MARK: - Helpers

    private func descriptor(start: Int32, end: Int32, text: String, isList: Bool) -> NSAppleEventDescriptor {
        let result = NSAppleEventDescriptor.list()
        result.insert(NSAppleEventDescriptor(string: "Document1"), at: 1)
        result.insert(NSAppleEventDescriptor(int32: start), at: 2)
        result.insert(NSAppleEventDescriptor(int32: end), at: 3)
        result.insert(NSAppleEventDescriptor(string: text), at: 4)
        result.insert(NSAppleEventDescriptor(boolean: isList), at: 5)
        return result
    }
}
