// RecordingStoreTests.swift
// OpenSuperMLXTests

import XCTest

import GRDB
@testable import OpenSuperMLX

@MainActor
final class RecordingStoreTests: XCTestCase {

    private var db: DatabaseQueue!
    private var sut: RecordingStore!

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        db = try DatabaseQueue()
        sut = RecordingStore(dbQueue: db)
    }

    override func tearDown() async throws {
        sut = nil
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
        progress: Float = 1.0
    ) -> Recording {
        Recording(
            id: id,
            timestamp: timestamp,
            fileName: fileName,
            transcription: transcription,
            duration: duration,
            status: status,
            progress: progress
        )
    }

    // MARK: - Tests

    func testSaveAndFetch() async throws {
        let recording = makeRecording(transcription: "Hello world")
        try await sut.addRecordingSync(recording)

        let fetched = try await sut.fetchRecordings(limit: 100, offset: 0)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.id, recording.id)
        XCTAssertEqual(fetched.first?.transcription, "Hello world")
        XCTAssertEqual(fetched.first?.fileName, "test.m4a")
        XCTAssertEqual(fetched.first?.status, .completed)
    }

    func testFetchAll_ReturnsInOrder() async throws {
        let now = Date()
        let r1 = makeRecording(timestamp: now.addingTimeInterval(-200), transcription: "oldest")
        let r2 = makeRecording(timestamp: now.addingTimeInterval(-100), transcription: "middle")
        let r3 = makeRecording(timestamp: now, transcription: "newest")

        try await sut.addRecordingSync(r1)
        try await sut.addRecordingSync(r2)
        try await sut.addRecordingSync(r3)

        let fetched = try await sut.fetchRecordings(limit: 100, offset: 0)
        XCTAssertEqual(fetched.count, 3)
        XCTAssertEqual(fetched[0].transcription, "newest")
        XCTAssertEqual(fetched[1].transcription, "middle")
        XCTAssertEqual(fetched[2].transcription, "oldest")
    }

    func testDelete() async throws {
        let recording = makeRecording(transcription: "to delete")
        try await sut.addRecordingSync(recording)

        let notificationExpectation = expectation(
            forNotification: RecordingStore.recordingsDidUpdateNotification,
            object: nil
        )
        sut.deleteRecording(recording)
        await fulfillment(of: [notificationExpectation], timeout: 5.0)

        let fetched = try await sut.fetchRecordings(limit: 100, offset: 0)
        XCTAssertTrue(fetched.isEmpty)
    }

    func testUpdate() async throws {
        var recording = makeRecording(transcription: "original")
        try await sut.addRecordingSync(recording)

        recording.transcription = "updated text"
        try await sut.updateRecordingSync(recording)

        let fetched = try await sut.fetchRecordings(limit: 100, offset: 0)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.transcription, "updated text")
    }

    func testSearch() async throws {
        let r1 = makeRecording(transcription: "Swift programming language")
        let r2 = makeRecording(transcription: "Python data science")
        let r3 = makeRecording(transcription: "Swift UI framework")

        try await sut.addRecordingSync(r1)
        try await sut.addRecordingSync(r2)
        try await sut.addRecordingSync(r3)

        let results = sut.searchRecordings(query: "Swift")
        XCTAssertEqual(results.count, 2)
        for result in results {
            XCTAssertTrue(result.transcription.contains("Swift"))
        }
    }

    // MARK: - Search Wildcard Escaping (regression)
    // SQL LIKE wildcards (%, _, \) in user input must match literally, not as wildcards.

    private func assertLiteralMatch(
        query: String,
        matching: String,
        notMatching: String,
        useAsync: Bool = false,
        file: StaticString = #file,
        line: UInt = #line
    ) async throws {
        try await sut.addRecordingSync(makeRecording(transcription: matching))
        try await sut.addRecordingSync(makeRecording(transcription: notMatching))

        let results = useAsync
            ? await sut.searchRecordingsAsync(query: query)
            : sut.searchRecordings(query: query)

        XCTAssertEqual(results.count, 1, file: file, line: line)
        XCTAssertEqual(results.first?.transcription, matching, file: file, line: line)
    }

    func testSearch_PercentIsLiteral() async throws {
        try await assertLiteralMatch(
            query: "100%", matching: "Battery at 100% charged", notMatching: "Battery at 100 charged"
        )
    }

    func testSearch_UnderscoreIsLiteral() async throws {
        try await assertLiteralMatch(
            query: "file_name", matching: "file_name.txt", notMatching: "fileXname.txt"
        )
    }

    func testSearch_BackslashIsLiteral() async throws {
        try await assertLiteralMatch(
            query: "path\\to", matching: "path\\to\\file", notMatching: "path/to/file"
        )
    }

    func testSearchAsync_PercentIsLiteral() async throws {
        try await assertLiteralMatch(
            query: "50%", matching: "discount 50% off", notMatching: "discount 50 off",
            useAsync: true
        )
    }

    func testMigrations() async throws {
        let freshDB = try DatabaseQueue()
        let store = RecordingStore(dbQueue: freshDB)

        let recording = makeRecording(transcription: "migration test")
        try await store.addRecordingSync(recording)

        let fetched = try await store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertEqual(fetched.count, 1, "Should insert and fetch after migrations")
        XCTAssertEqual(fetched.first?.transcription, "migration test")
    }
}
