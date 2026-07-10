// TranscriptSessionStoreTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class TranscriptSessionStoreTests: XCTestCase {

    private var sut: TranscriptSessionStore!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        sut = TranscriptSessionStore()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testDeltaReturnsSegmentsAfterCursorAndPreservesCursorWhenEmpty() throws {
        let sessionID = sut.startSession(startedAt: Date(timeIntervalSince1970: 100))
        let first = try sut.appendSegment(
            sessionID: sessionID,
            kind: .final,
            text: "first point",
            startMs: 1_000,
            endMs: 2_000
        )
        let second = try sut.appendSegment(
            sessionID: sessionID,
            kind: .final,
            text: "second point",
            startMs: 2_000,
            endMs: 3_000
        )

        let delta = try sut.transcriptDelta(
            sessionID: sessionID,
            afterCursor: first.cursor,
            maxSegments: 10,
            includeProvisional: true
        )

        XCTAssertEqual(delta.segments.map(\.text), ["second point"])
        XCTAssertEqual(delta.nextCursor, second.cursor)
        XCTAssertFalse(delta.hasMore)

        let empty = try sut.transcriptDelta(
            sessionID: sessionID,
            afterCursor: second.cursor,
            maxSegments: 10,
            includeProvisional: true
        )
        XCTAssertTrue(empty.segments.isEmpty)
        XCTAssertEqual(empty.nextCursor, second.cursor)
        XCTAssertFalse(empty.hasMore)
    }

    func testDeltaIsBoundedAndReportsHasMore() throws {
        let sessionID = sut.startSession(startedAt: Date(timeIntervalSince1970: 100))
        _ = try sut.appendSegment(sessionID: sessionID, kind: .final, text: "one", startMs: 0, endMs: 1_000)
        _ = try sut.appendSegment(sessionID: sessionID, kind: .final, text: "two", startMs: 1_000, endMs: 2_000)
        _ = try sut.appendSegment(sessionID: sessionID, kind: .final, text: "three", startMs: 2_000, endMs: 3_000)

        let delta = try sut.transcriptDelta(
            sessionID: sessionID,
            afterCursor: nil,
            maxSegments: 2,
            includeProvisional: true
        )

        XCTAssertEqual(delta.segments.map(\.text), ["one", "two"])
        XCTAssertEqual(delta.nextCursor, "seg_000002")
        XCTAssertTrue(delta.hasMore)
    }

    func testDisplayUpdateStoresOnlyConfirmedDeltaPlusChangedProvisional() throws {
        let sessionID = sut.startSession(startedAt: Date(timeIntervalSince1970: 100))

        try sut.recordDisplayUpdate(
            sessionID: sessionID,
            confirmedText: "hello",
            provisionalText: " wor",
            elapsedMs: 1_000
        )
        try sut.recordDisplayUpdate(
            sessionID: sessionID,
            confirmedText: "hello world",
            provisionalText: "",
            elapsedMs: 2_000
        )

        let all = try sut.transcriptDelta(
            sessionID: sessionID,
            afterCursor: nil,
            maxSegments: 10,
            includeProvisional: true
        )

        XCTAssertEqual(all.segments.map(\.kind), [.final, .provisional, .final])
        XCTAssertEqual(all.segments.map(\.text), ["hello", " wor", " world"])

        let finalOnly = try sut.transcriptDelta(
            sessionID: sessionID,
            afterCursor: nil,
            maxSegments: 10,
            includeProvisional: false
        )
        XCTAssertEqual(finalOnly.segments.map(\.text), ["hello", " world"])
    }

    func testSearchReturnsCaseInsensitiveFinalMatchesWithBoundedContext() throws {
        let sessionID = sut.startSession(startedAt: Date(timeIntervalSince1970: 100))
        _ = try sut.appendSegment(sessionID: sessionID, kind: .final, text: "before context", startMs: 0, endMs: 1_000)
        let match = try sut.appendSegment(sessionID: sessionID, kind: .final, text: "API latency is the key issue", startMs: 1_000, endMs: 2_000)
        _ = try sut.appendSegment(sessionID: sessionID, kind: .provisional, text: "latency maybe duplicate", startMs: 2_000, endMs: 3_000)
        _ = try sut.appendSegment(sessionID: sessionID, kind: .final, text: "after context", startMs: 3_000, endMs: 4_000)

        let response = try sut.searchTranscript(
            query: "LATENCY",
            sessionID: sessionID,
            limit: 10,
            contextSegments: 1,
            includeProvisional: false
        )

        XCTAssertEqual(response.matches.count, 1)
        XCTAssertEqual(response.matches.first?.segment.cursor, match.cursor)
        XCTAssertEqual(response.matches.first?.context.map(\.text), ["before context", "API latency is the key issue", "after context"])
    }

    func testWindowReturnsSegmentsAroundCursor() throws {
        let sessionID = sut.startSession(startedAt: Date(timeIntervalSince1970: 100))
        _ = try sut.appendSegment(sessionID: sessionID, kind: .final, text: "one", startMs: 0, endMs: 1_000)
        let middle = try sut.appendSegment(sessionID: sessionID, kind: .final, text: "two", startMs: 1_000, endMs: 2_000)
        _ = try sut.appendSegment(sessionID: sessionID, kind: .final, text: "three", startMs: 2_000, endMs: 3_000)

        let window = try sut.transcriptWindow(
            sessionID: sessionID,
            aroundCursor: middle.cursor,
            beforeSegments: 1,
            afterSegments: 1,
            includeProvisional: true
        )

        XCTAssertEqual(window.segments.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(window.anchorCursor, middle.cursor)
    }
}
