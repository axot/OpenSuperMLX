// StreamingAudioServiceTranscriptTests.swift
// OpenSuperMLXTests

import XCTest

import MLXAudioSTT
@testable import OpenSuperMLX

@MainActor
final class StreamingAudioServiceTranscriptTests: XCTestCase {

    private var store: TranscriptSessionStore!
    private var sut: StreamingAudioService!

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        store = TranscriptSessionStore()
        sut = StreamingAudioService.shared
        sut.transcriptSessionStore = store
        sut.endCurrentTranscriptSession()
    }

    override func tearDown() async throws {
        sut.endCurrentTranscriptSession()
        sut.transcriptSessionStore = .shared
        sut = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - Tests

    func testDisplayUpdatesAreRecordedAsTranscriptSegments() throws {
        let sessionID = sut.beginTranscriptSession(startedAt: Date(timeIntervalSince1970: 100))

        sut.recordTranscriptEvent(.displayUpdate(confirmedText: "hello", provisionalText: " wor"), elapsedMs: 1_000)
        sut.recordTranscriptEvent(.displayUpdate(confirmedText: "hello world", provisionalText: ""), elapsedMs: 2_000)

        let delta = try store.transcriptDelta(
            sessionID: sessionID,
            afterCursor: nil,
            maxSegments: 10,
            includeProvisional: true
        )

        XCTAssertEqual(delta.segments.map(\.kind), [.final, .provisional, .final])
        XCTAssertEqual(delta.segments.map(\.text), ["hello", " wor", " world"])
    }

    func testEndedEventClosesCurrentTranscriptSession() throws {
        let sessionID = sut.beginTranscriptSession(startedAt: Date(timeIntervalSince1970: 100))

        sut.recordTranscriptEvent(.displayUpdate(confirmedText: "final", provisionalText: ""), elapsedMs: 1_000)
        sut.recordTranscriptEvent(.ended(fullText: "final text"), elapsedMs: 2_000)

        XCTAssertNil(sut.currentTranscriptSessionID)
        let sessions = store.listSessions(limit: 1)
        XCTAssertEqual(sessions.first?.sessionID, sessionID)
        XCTAssertNotNil(sessions.first?.endedAt)
    }

    func testEventsWithoutActiveTranscriptSessionAreIgnored() throws {
        sut.recordTranscriptEvent(.displayUpdate(confirmedText: "ignored", provisionalText: ""), elapsedMs: 1_000)

        XCTAssertTrue(store.listSessions().isEmpty)
    }
}
