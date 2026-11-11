// RecordingDetailsStateTests.swift
// OpenSuperMLXTests

import Combine
import XCTest

@testable import OpenSuperMLX

final class RecordingDetailsStateTests: XCTestCase {
    func testSelectingHistoryOpensDetails() {
        var state = RecordingDetailsState()
        let id = UUID()
        XCTAssertNil(state.selection)
        state.selectRecording(id)
        XCTAssertEqual(state.selection, .recording(id))
    }

    func testDockSwitchesHistoryToLiveThenCloses() {
        var state = RecordingDetailsState()
        state.selectRecording(UUID())
        state.toggleCurrent(isRecording: true)
        XCTAssertEqual(state.selection, .live)
        state.toggleCurrent(isRecording: true)
        XCTAssertNil(state.selection)
    }

    func testCompletionReplacesOnlyLiveSelection() {
        let savedID = UUID()
        let historyID = UUID()
        var state = RecordingDetailsState()
        state.toggleCurrent(isRecording: true)
        state.recordingCompleted(savedID)
        XCTAssertEqual(state.selection, .recording(savedID))
        state.selectRecording(historyID)
        state.recordingCompleted(UUID())
        XCTAssertEqual(state.selection, .recording(historyID))
        state.close()
        state.recordingCompleted(UUID())
        XCTAssertNil(state.selection)
    }

    func testIdleDockOpensLatestSavedRecording() {
        var state = RecordingDetailsState()
        state.toggleCurrent(isRecording: false)
        XCTAssertNil(state.selection)
        let id = UUID()
        state.recordingCompleted(id)
        state.toggleCurrent(isRecording: false)
        XCTAssertEqual(state.selection, .recording(id))
        state.toggleCurrent(isRecording: false)
        XCTAssertNil(state.selection)
    }

    func testNewSessionKeepsHistoryAndChangesLiveIdentity() {
        var state = RecordingDetailsState()
        let id = UUID()
        state.selectRecording(id)
        let previous = state.liveSessionID
        state.beginRecording()
        XCTAssertNotEqual(state.liveSessionID, previous)
        XCTAssertEqual(state.selection, .recording(id))
        XCTAssertNil(state.lastSavedRecordingID)
    }

    func testDeletingSelectedRecordingClosesOnlyItsDetails() {
        var state = RecordingDetailsState()
        let id = UUID()
        state.recordingCompleted(id)
        state.selectRecording(id)
        state.removeRecording(UUID())
        XCTAssertEqual(state.selection, .recording(id))
        state.removeRecording(id)
        XCTAssertNil(state.selection)
        XCTAssertNil(state.lastSavedRecordingID)
    }

    func testUnsuccessfulStopClosesLiveButPreservesHistory() {
        var state = RecordingDetailsState()
        state.toggleCurrent(isRecording: true)
        state.recordingStopped(savedID: nil)
        XCTAssertNil(state.selection)
        let id = UUID()
        state.selectRecording(id)
        state.recordingStopped(savedID: nil)
        XCTAssertEqual(state.selection, .recording(id))
    }

    func testClearingHistoryPreservesLiveDetails() {
        var state = RecordingDetailsState()
        state.recordingCompleted(UUID())
        state.toggleCurrent(isRecording: true)
        state.clearRecordings()
        XCTAssertEqual(state.selection, .live)
        XCTAssertNil(state.lastSavedRecordingID)
        state.selectRecording(UUID())
        state.clearRecordings()
        XCTAssertNil(state.selection)
    }
}

final class LiveTranscriptSnapshotTests: XCTestCase {
    func testEmptyRecoveryUpdateWithdrawsThePreviousDraft() {
        var snapshot = LiveTranscriptSnapshot()
        snapshot.capture(confirmed: "", provisional: "withdrawn draft")
        snapshot.capture(confirmed: "", provisional: "")
        XCTAssertEqual(snapshot.text, "")
        XCTAssertEqual(snapshot.provisional, "")
    }

    func testFinalPublicationSurvivesImmediateServiceClearing() {
        let updates = CurrentValueSubject<LiveTranscriptSnapshot?, Never>(nil)
        var snapshot = LiveTranscriptSnapshot()
        let subscription = updates.compactMap { $0 }.sink { snapshot = $0 }
        var draft = LiveTranscriptSnapshot()
        draft.capture(confirmed: "accepted", provisional: " rejected draft")
        updates.send(draft)
        var final = LiveTranscriptSnapshot()
        final.capture(confirmed: "accepted final residual words", provisional: "")
        updates.send(final)
        updates.send(nil)
        XCTAssertEqual(snapshot.text, "accepted final residual words")
        XCTAssertEqual(snapshot.provisional, "")
        withExtendedLifetime(subscription) {}
    }

    func testEmptyDisplayPublicationClearsBeforeTeardown() {
        let updates = CurrentValueSubject<LiveTranscriptSnapshot?, Never>(nil)
        var snapshot = LiveTranscriptSnapshot()
        let subscription = updates.compactMap { $0 }.sink { snapshot = $0 }
        var draft = LiveTranscriptSnapshot()
        draft.capture(confirmed: "", provisional: "withdrawn draft")
        updates.send(draft)
        updates.send(LiveTranscriptSnapshot())
        updates.send(nil)
        XCTAssertEqual(snapshot.text, "")
        withExtendedLifetime(subscription) {}
    }

    func testSnapshotPreservesPendingWhitespaceAndInvisibleText() {
        var snapshot = LiveTranscriptSnapshot()
        snapshot.capture(confirmed: "中文 ", provisional: "\nEnglish\u{200B}")
        XCTAssertEqual(snapshot.text, "中文 \nEnglish\u{200B}")
    }

    func testReplacingPendingTextDoesNotDuplicateIt() {
        var snapshot = LiveTranscriptSnapshot()
        snapshot.capture(confirmed: "accepted ", provisional: "old")
        snapshot.capture(confirmed: "accepted ", provisional: "new")
        XCTAssertEqual(snapshot.text, "accepted new")
    }

    func testNewSnapshotDoesNotRetainThePreviousSession() {
        var snapshot = LiveTranscriptSnapshot()
        snapshot.capture(confirmed: "previous", provisional: " draft")
        snapshot = LiveTranscriptSnapshot()
        XCTAssertTrue(snapshot.text.isEmpty)
    }
}
