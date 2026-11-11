// RecordingTests.swift
// OpenSuperMLXTests

import Foundation
import XCTest

@testable import OpenSuperMLX

@MainActor
final class RecordingTests: XCTestCase {
    func testProgressNotificationRefreshesAnIndependentRecordingSnapshot() {
        var recording = makeRecording()
        let notification = Notification(name: RecordingStore.recordingProgressDidUpdateNotification, userInfo: [
            "id": recording.id, "transcription": "New complete transcript",
            "progress": Float(1), "status": RecordingStatus.completed, "isRegeneration": false,
        ])
        recording.applyProgressUpdate(notification)
        XCTAssertEqual(recording.transcription, "New complete transcript")
        XCTAssertEqual(recording.progress, 1)
        XCTAssertEqual(recording.status, .completed)
        XCTAssertFalse(recording.isRegeneration)
    }

    func testUnrelatedAndIncompleteNotificationsPreserveTheSnapshot() {
        var recording = makeRecording()
        let original = recording
        recording.applyProgressUpdate(Notification(name: RecordingStore.recordingProgressDidUpdateNotification, userInfo: [
            "id": UUID(), "transcription": "Unrelated", "progress": Float(1), "status": RecordingStatus.completed,
        ]))
        recording.applyProgressUpdate(Notification(name: RecordingStore.recordingProgressDidUpdateNotification, userInfo: [
            "id": recording.id, "transcription": "Incomplete",
        ]))
        XCTAssertEqual(recording, original)
    }

    func testStatusOnlyNotificationPreservesTextAndRegenerationFlag() {
        var recording = makeRecording()
        recording.applyProgressUpdate(Notification(name: RecordingStore.recordingProgressDidUpdateNotification, userInfo: [
            "id": recording.id, "progress": Float(0.5), "status": RecordingStatus.transcribing,
        ]))
        XCTAssertEqual(recording.transcription, "Original transcript")
        XCTAssertEqual(recording.progress, 0.5)
        XCTAssertEqual(recording.status, .transcribing)
        XCTAssertTrue(recording.isRegeneration)
    }

    func testEmptyTranscriptionReplacesPreviousContents() {
        var recording = makeRecording()
        recording.applyProgressUpdate(Notification(name: RecordingStore.recordingProgressDidUpdateNotification, userInfo: [
            "id": recording.id, "transcription": "", "progress": Float(1), "status": RecordingStatus.completed,
        ]))
        XCTAssertEqual(recording.transcription, "")
    }

    func testCanonicalTranscriptionReplacementChangesRecordingEquality() {
        var original = makeRecording()
        original.transcription = "e\u{301}"
        var replaced = original
        replaced.transcription = "é"
        XCTAssertNotEqual(original, replaced)
    }

    private func makeRecording() -> Recording {
        Recording(
            id: UUID(), timestamp: Date(timeIntervalSince1970: 1), fileName: "synthetic.m4a",
            transcription: "Original transcript", duration: 12, status: .pending,
            progress: 0, isRegeneration: true
        )
    }
}
