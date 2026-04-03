// DualTrackTranscriptionTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

@MainActor
final class DualTrackTranscriptionTests: XCTestCase {
    private var sut: TranscriptionService!
    private var mockEngine: MockTranscriptionEngine!

    override func setUp() async throws {
        try await super.setUp()
        mockEngine = MockTranscriptionEngine()
        sut = TranscriptionService(engine: mockEngine)
    }

    override func tearDown() async throws {
        sut = nil
        mockEngine = nil
        try await super.tearDown()
    }

    // MARK: - TranscriptionSegment & SegmentSource

    func testSegmentSourceHasCorrectCases() {
        let mic = SegmentSource.microphone
        let sys = SegmentSource.systemAudio

        XCTAssertNotEqual(
            String(describing: mic),
            String(describing: sys)
        )
    }

    func testTranscriptionSegmentCanBeCreated() {
        let segment = TranscriptionSegment(
            text: "hello",
            startTime: 0.0,
            endTime: 1.5,
            source: .microphone
        )

        XCTAssertEqual(segment.text, "hello")
        XCTAssertEqual(segment.startTime, 0.0)
        XCTAssertEqual(segment.endTime, 1.5)
        XCTAssertEqual(segment.source, .microphone)
    }

    // MARK: - mergeTranscripts

    func testMergeTranscriptsInterleavesByStartTime() {
        let micSegments = [
            TranscriptionSegment(text: "mic first", startTime: 0.0, endTime: 2.0, source: .microphone),
            TranscriptionSegment(text: "mic third", startTime: 5.0, endTime: 7.0, source: .microphone),
        ]
        let systemSegments = [
            TranscriptionSegment(text: "sys second", startTime: 3.0, endTime: 4.0, source: .systemAudio),
            TranscriptionSegment(text: "sys fourth", startTime: 8.0, endTime: 10.0, source: .systemAudio),
        ]

        let result = sut.mergeTranscripts(micSegments: micSegments, systemSegments: systemSegments)

        XCTAssertEqual(result, "mic first\nsys second\nmic third\nsys fourth")
    }

    func testMergeTranscriptsWithEmptySystemSegmentsReturnsMicOnly() {
        let micSegments = [
            TranscriptionSegment(text: "only mic", startTime: 0.0, endTime: 2.0, source: .microphone),
            TranscriptionSegment(text: "still mic", startTime: 3.0, endTime: 5.0, source: .microphone),
        ]

        let result = sut.mergeTranscripts(micSegments: micSegments, systemSegments: [])

        XCTAssertEqual(result, "only mic\nstill mic")
    }

    func testMergeTranscriptsWithOverlappingTimestampsKeepsBoth() {
        let micSegments = [
            TranscriptionSegment(text: "mic talking", startTime: 1.0, endTime: 4.0, source: .microphone),
        ]
        let systemSegments = [
            TranscriptionSegment(text: "sys talking", startTime: 2.0, endTime: 5.0, source: .systemAudio),
        ]

        let result = sut.mergeTranscripts(micSegments: micSegments, systemSegments: systemSegments)

        XCTAssertTrue(result.contains("mic talking"))
        XCTAssertTrue(result.contains("sys talking"))
        XCTAssertEqual(result, "mic talking\nsys talking")
    }

    func testMergeTranscriptsWithBothEmptyReturnsEmpty() {
        let result = sut.mergeTranscripts(micSegments: [], systemSegments: [])

        XCTAssertEqual(result, "")
    }

    func testMergeTranscriptsWithSameStartTimeMicComesFirst() {
        let micSegments = [
            TranscriptionSegment(text: "mic", startTime: 1.0, endTime: 2.0, source: .microphone),
        ]
        let systemSegments = [
            TranscriptionSegment(text: "sys", startTime: 1.0, endTime: 2.0, source: .systemAudio),
        ]

        let result = sut.mergeTranscripts(micSegments: micSegments, systemSegments: systemSegments)

        // Both kept; stable sort means mic first since it appears first in combined array
        XCTAssertEqual(result, "mic\nsys")
    }

    // MARK: - handleDualTrackCompletion return value

    func testHandleDualTrackCompletionReturnsSystemAudioText() async throws {
        mockEngine.transcribeResult = "system audio text"
        let tempDir = FileManager.default.temporaryDirectory
        let fakeAudio = tempDir.appendingPathComponent("test_system_audio_\(UUID().uuidString).wav")
        try Data([0]).write(to: fakeAudio)
        defer { try? FileManager.default.removeItem(at: fakeAudio) }

        let result = await sut.handleDualTrackCompletion(
            systemAudioURL: fakeAudio,
            outputType: .headphones,
            micTranscription: "",
            recordingId: UUID()
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("system audio text") == true)
    }

    func testHandleDualTrackCompletionReturnsNilForNoSystemAudio() async {
        let result = await sut.handleDualTrackCompletion(
            systemAudioURL: nil,
            outputType: .headphones,
            micTranscription: "mic text",
            recordingId: UUID()
        )

        XCTAssertNil(result)
    }
}
