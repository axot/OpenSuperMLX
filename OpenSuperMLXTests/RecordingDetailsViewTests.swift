// RecordingDetailsViewTests.swift
// OpenSuperMLXTests

import AppKit
import SwiftUI
import XCTest

@testable import OpenSuperMLX

@MainActor
final class RecordingDetailsViewTests: XCTestCase {
    func testLiveDocumentPreservesConfirmedAndPendingText() {
        let id = UUID()
        let document = RecordingDetailDocument.live(
            sessionID: id,
            confirmed: "中文 \nEnglish",
            provisional: " pending\u{200B}",
            deviceName: "Test microphone",
            duration: 12,
            isProcessing: false
        )
        XCTAssertEqual(document.id, .live(id))
        XCTAssertEqual(document.text, "中文 \nEnglish pending\u{200B}")
        XCTAssertEqual(document.phase, .live)
    }

    func testSavedDocumentUsesOriginalFullTextAndRecordingIdentity() {
        let recording = Recording(
            id: UUID(), timestamp: Date(timeIntervalSince1970: 1),
            fileName: "test.m4a", transcription: "First\n\nLast",
            duration: 80, status: .completed, progress: 1,
            sourceFileURL: "/example/meeting.wav"
        )
        let document = RecordingDetailDocument.saved(recording)
        XCTAssertEqual(document.id, .recording(recording.id))
        XCTAssertEqual(document.title, "meeting.wav")
        XCTAssertEqual(document.text, recording.transcription)
        XCTAssertEqual(document.duration, 80)
        XCTAssertEqual(document.phase, .completed)
    }

    func testCharacterCountExcludesWhitespaceAndCountsGraphemes() {
        let document = RecordingDetailDocument.live(
            sessionID: UUID(), confirmed: " 你好\n e\u{301} 👨‍👩‍👦 \t",
            provisional: "", deviceName: "", duration: 0, isProcessing: false
        )
        XCTAssertEqual(document.characterCount, 4)
    }

    func testAppendingTextPreservesSelectionAndExactUnicode() {
        let view = NSTextView()
        TranscriptTextView.updateText(view, text: "你好 ")
        view.setSelectedRange(NSRange(location: 0, length: 2))
        TranscriptTextView.updateText(view, text: "你好 🎙\nnext")
        XCTAssertEqual(view.string, "你好 🎙\nnext")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 2))
    }

    func testReplacingTextClampsSelectionWithoutRetainingOldSuffix() {
        let view = NSTextView()
        TranscriptTextView.updateText(view, text: "old rejected suffix")
        view.setSelectedRange(NSRange(location: 10, length: 8))
        TranscriptTextView.updateText(view, text: "new")
        XCTAssertEqual(view.string, "new")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
    }

    func testSearchHighlightsDoNotChangeTranscriptContents() {
        let view = NSTextView()
        TranscriptTextView.updateText(view, text: "one one")
        TranscriptTextView.highlight(
            view, ranges: [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)],
            selectedRange: NSRange(location: 4, length: 3)
        )
        XCTAssertEqual(view.string, "one one")
        XCTAssertNotNil(view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 4, effectiveRange: nil))
        TranscriptTextView.highlight(view, ranges: [], selectedRange: nil)
        XCTAssertNil(view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 4, effectiveRange: nil))
    }

    func testEquivalentUnicodeReplacementPreservesExactTextStorage() {
        let view = NSTextView()
        TranscriptTextView.updateText(view, text: "e\u{301}")
        TranscriptTextView.updateText(view, text: "é")
        XCTAssertEqual(Array(view.string.utf16), Array("é".utf16))
    }

    func testStaleSearchRangesCannotAffectShorterText() {
        let view = NSTextView()
        TranscriptTextView.updateText(view, text: "one")
        TranscriptTextView.highlight(
            view, ranges: [NSRange(location: 0, length: 3), NSRange(location: 100, length: 3)],
            selectedRange: NSRange(location: 100, length: 3)
        )
        XCTAssertEqual(view.string, "one")
        XCTAssertNotNil(view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil))
    }
}

@MainActor
final class TranscriptReaderInteractionTests: XCTestCase {
    func testKeyboardScrollCommandsPauseFollow() {
        let scrollView = TranscriptScrollView()
        let textView = TranscriptNativeTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 2000))
        scrollView.documentView = textView
        var calls = 0
        textView.onManualScroll = { calls += 1 }
        textView.scrollPageUp(nil)
        textView.scrollPageDown(nil)
        textView.scrollToBeginningOfDocument(nil)
        textView.scrollToEndOfDocument(nil)
        XCTAssertGreaterThanOrEqual(calls, 4)
    }

    func testProgrammaticScrollDoesNotPauseFollow() {
        let textView = TranscriptNativeTextView()
        var calls = 0
        textView.onManualScroll = { calls += 1 }
        textView.isUpdating = true
        textView.scrollPageUp(nil)
        XCTAssertEqual(calls, 0)
    }

    func testReaderEscapeRoutesToSearchAction() {
        let view = TranscriptNativeTextView()
        var called = false
        view.onEscape = { called = true }
        view.cancelOperation(nil)
        XCTAssertTrue(called)
    }
}

@MainActor
final class TranscriptSearchFieldTests: XCTestCase {
    func testNativeEditingPublishesBothUnicodeRepresentations() {
        let coordinator = TranscriptSearchField.Coordinator()
        let field = NSTextField()
        var values: [[UInt16]] = []
        coordinator.onTextChange = { values.append(Array($0.utf16)) }
        field.stringValue = "e\u{301}"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        field.stringValue = "é"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(values, [Array("e\u{301}".utf16), Array("é".utf16)])
    }

    func testEscapeInvokesTheSharedClearOrCloseAction() {
        let coordinator = TranscriptSearchField.Coordinator()
        var calls = 0
        coordinator.onEscape = { calls += 1 }
        let handled = coordinator.control(
            NSTextField(), textView: NSTextView(), doCommandBy: NSSelectorFromString("cancelOperation:")
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(calls, 1)
    }

    func testMatchNavigationRespectsShift() {
        let coordinator = TranscriptSearchField.Coordinator()
        var directions: [Int] = []
        coordinator.onNavigate = { directions.append($0) }
        coordinator.navigate(modifiers: [])
        coordinator.navigate(modifiers: [.shift])
        XCTAssertEqual(directions, [1, -1])
    }

    func testOtherCommandsKeepNativeEditingBehavior() {
        let coordinator = TranscriptSearchField.Coordinator()
        XCTAssertFalse(coordinator.control(
            NSTextField(), textView: NSTextView(), doCommandBy: NSSelectorFromString("moveLeft:")
        ))
    }
}
