// RecordingsCommandTests.swift
// OpenSuperMLXTests

import XCTest

import GRDB
@testable import OpenSuperMLX

@MainActor
final class RecordingsCommandTests: XCTestCase {

    private var db: DatabaseQueue!
    private var store: RecordingStore!

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        db = try DatabaseQueue()
        store = RecordingStore(dbQueue: db)
    }

    override func tearDown() async throws {
        store = nil
        db = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeRecording(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        fileName: String = "test.m4a",
        transcription: String = "",
        duration: TimeInterval = 5.0,
        status: RecordingStatus = .completed,
        progress: Float = 1.0,
        sourceFileURL: String? = nil
    ) -> Recording {
        Recording(
            id: id,
            timestamp: timestamp,
            fileName: fileName,
            transcription: transcription,
            duration: duration,
            status: status,
            progress: progress,
            sourceFileURL: sourceFileURL
        )
    }

    // MARK: - List

    func testRecordingsListEmpty() async throws {
        let result = await RecordingsListCommand.executeList(store: store, limit: 20, offset: 0)
        guard case .success(let entries) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertTrue(entries.isEmpty)
    }

    func testRecordingsListWithData() async throws {
        let now = Date()
        let r1 = makeRecording(timestamp: now.addingTimeInterval(-100), transcription: "Hello world", duration: 3.0)
        let r2 = makeRecording(timestamp: now, transcription: "Goodbye", duration: 7.0)
        try await store.addRecordingSync(r1)
        try await store.addRecordingSync(r2)

        let result = await RecordingsListCommand.executeList(store: store, limit: 20, offset: 0)
        guard case .success(let entries) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].id, r2.id.uuidString)
        XCTAssertEqual(entries[1].id, r1.id.uuidString)
    }

    // MARK: - Search

    func testRecordingsSearchMatchesText() async throws {
        let r1 = makeRecording(transcription: "Swift programming language")
        let r2 = makeRecording(transcription: "Python data science")
        try await store.addRecordingSync(r1)
        try await store.addRecordingSync(r2)

        let result = await RecordingsSearchCommand.executeSearch(store: store, query: "Swift")
        guard case .success(let entries) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].transcription, "Swift programming language")
    }

    // MARK: - Show

    func testRecordingsShowById() async throws {
        let recording = makeRecording(transcription: "Test recording", duration: 10.0)
        try await store.addRecordingSync(recording)

        let result = await RecordingsShowCommand.executeShow(store: store, id: recording.id.uuidString)
        guard case .success(let entry) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertEqual(entry.id, recording.id.uuidString)
        XCTAssertEqual(entry.transcription, "Test recording")
        XCTAssertEqual(entry.duration, 10.0)
    }

    func testRecordingsShowNonExistent() async throws {
        let result = await RecordingsShowCommand.executeShow(store: store, id: UUID().uuidString)
        guard case .failure(let error) = result else {
            XCTFail("Expected failure"); return
        }
        XCTAssertEqual(error, .databaseError)
    }

    // MARK: - Delete

    func testRecordingsDeleteById() async throws {
        let recording = makeRecording(transcription: "To delete")
        try await store.addRecordingSync(recording)

        let result = await RecordingsDeleteCommand.executeDelete(store: store, id: recording.id.uuidString, all: false)
        guard case .success(let msg) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertTrue(msg.message.contains("Deleted"))

        let notificationExpectation = expectation(
            forNotification: RecordingStore.recordingsDidUpdateNotification,
            object: nil
        )
        await fulfillment(of: [notificationExpectation], timeout: 5.0)

        let remaining = try await store.fetchRecordings(limit: 100, offset: 0)
        XCTAssertTrue(remaining.isEmpty)
    }
}
