// TranscriptionQueueTests.swift
// OpenSuperMLXTests

import XCTest

import GRDB
@testable import OpenSuperMLX

@MainActor
final class TranscriptionQueueTests: XCTestCase {

    func testMissingAudioPreservesOriginalTranscription() async throws {
        let store = RecordingStore(dbQueue: try DatabaseQueue())
        let recording = makeRecording(
            fileName: "missing-\(UUID().uuidString).m4a",
            transcription: "original transcript",
            sourceFileURL: "/tmp/missing-\(UUID().uuidString).m4a"
        )
        try await store.addRecordingSync(recording)
        var warning: String?
        let queue = TranscriptionQueue(
            transcriptionService: TranscriptionService(engine: nil),
            recordingStore: store,
            onMissingAudio: { warning = $0 },
            observesProgress: false
        )

        await queue.requeueRecording(recording)

        let recordings = try await store.fetchRecordings(limit: 1, offset: 0)
        let saved = try XCTUnwrap(recordings.first)
        XCTAssertEqual(saved.transcription, "original transcript")
        XCTAssertEqual(saved.status, .failed)
        XCTAssertEqual(saved.progress, 0)
        XCTAssertEqual(warning, "Audio file not found. Original transcript was kept.")
    }

    func testRegenerationSourcePrefersImportedFile() {
        let recording = makeRecording(
            fileName: "stored.m4a",
            sourceFileURL: "/tmp/imported.wav"
        )

        let source = TranscriptionQueue.resolveRegenerationSource(
            for: recording,
            fileExists: { $0.path == "/tmp/imported.wav" }
        )

        XCTAssertEqual(source?.path, "/tmp/imported.wav")
    }

    func testRegenerationSourceFallsBackToStoredAudioOrNil() {
        let recording = makeRecording(
            fileName: "stored-\(UUID().uuidString).m4a",
            sourceFileURL: "/tmp/missing.wav"
        )

        let storedSource = TranscriptionQueue.resolveRegenerationSource(
            for: recording,
            fileExists: { $0 == recording.url }
        )
        let missingSource = TranscriptionQueue.resolveRegenerationSource(
            for: recording,
            fileExists: { _ in false }
        )

        XCTAssertEqual(storedSource, recording.url)
        XCTAssertNil(missingSource)
    }

    func testMissingPendingRegenerationIsPreservedInsteadOfDeleted() {
        let regeneration = makeRecording(
            fileName: "regeneration.m4a",
            transcription: "original transcript"
        )
        let newImport = makeRecording(
            fileName: "new-import.m4a",
            transcription: ""
        )

        XCTAssertFalse(TranscriptionQueue.shouldDeleteMissingPendingRecording(regeneration))
        XCTAssertTrue(TranscriptionQueue.shouldDeleteMissingPendingRecording(newImport))
    }

    private func makeRecording(
        fileName: String,
        transcription: String = "original transcript",
        sourceFileURL: String? = nil
    ) -> Recording {
        Recording(
            id: UUID(),
            timestamp: Date(),
            fileName: fileName,
            transcription: transcription,
            duration: 5,
            status: .completed,
            progress: 1,
            sourceFileURL: sourceFileURL
        )
    }
}
