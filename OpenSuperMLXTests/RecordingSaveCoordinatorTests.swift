// RecordingSaveCoordinatorTests.swift
// OpenSuperMLXTests

import AVFoundation
import Foundation
import XCTest

import GRDB
@testable import OpenSuperMLX

@MainActor
final class RecordingSaveCoordinatorTests: XCTestCase {

    func testNormalSaveInstallsDirectAudioAndPersists() async throws {
        let environment = try SaveEnvironment()
        defer { environment.cleanup() }
        let sourceURL = environment.directory.appendingPathComponent("direct.m4a")
        try Data("direct".utf8).write(to: sourceURL)
        let outcome = makeOutcome(audioURL: sourceURL)
        let coordinator = RecordingSaveCoordinator(dependencies: environment.dependencies())

        let recording = await coordinator.save(outcome)

        XCTAssertEqual(recording?.fileName, outcome.fileName)
        XCTAssertTrue(environment.storedIDs.contains(outcome.recordingID))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: environment.directory.appendingPathComponent(outcome.fileName).path
        ))
        XCTAssertTrue(coordinator.isIdle)
    }

    func testMissingAudioEncodesEntireRetryBufferWithRealAAC() async throws {
        let environment = try SaveEnvironment(useRealCodec: true)
        defer { environment.cleanup() }
        var buffer = PCMRetryBuffer()
        buffer.append([Float](repeating: 0.1, count: 16_000))
        let outcome = makeOutcome(
            audioURL: nil,
            storageError: CocoaError(.fileWriteUnknown),
            retryBuffer: buffer,
            duration: 9
        )
        let coordinator = RecordingSaveCoordinator(dependencies: environment.dependencies())

        let recording = await coordinator.save(outcome)

        XCTAssertNotNil(recording)
        XCTAssertEqual(environment.encodedSampleCounts, [16_000])
        let file = try AVAudioFile(forReading: environment.directory.appendingPathComponent(outcome.fileName))
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
    }

    func testSaveFailureEntersRecoveryAndRetrySucceedsWithSameFileName() async throws {
        let environment = try SaveEnvironment()
        defer { environment.cleanup() }
        environment.encodeFailuresRemaining = 1
        let outcome = makeOutcome(
            audioURL: nil,
            storageError: CocoaError(.fileWriteOutOfSpace)
        )
        let coordinator = RecordingSaveCoordinator(dependencies: environment.dependencies())

        let initialRecording = await coordinator.save(outcome)
        XCTAssertNil(initialRecording)
        XCTAssertTrue(coordinator.hasPendingSave)
        guard case .awaitingUser(_, let storageError) = coordinator.state else {
            return XCTFail("Expected recovery state")
        }
        XCTAssertEqual(storageError.category, .outOfSpace)
        let recording = await coordinator.retry()

        XCTAssertEqual(recording?.fileName, outcome.fileName)
        XCTAssertEqual(environment.encodedSampleCounts, [outcome.retryBuffer.count, outcome.retryBuffer.count])
        XCTAssertTrue(coordinator.isIdle)
    }

    func testRepeatedRetryFailureKeepsPendingPayload() async throws {
        let environment = try SaveEnvironment()
        defer { environment.cleanup() }
        environment.encodeFailuresRemaining = 10
        let outcome = makeOutcome(audioURL: nil, storageError: SaveTestError.failure)
        let coordinator = RecordingSaveCoordinator(dependencies: environment.dependencies())

        _ = await coordinator.save(outcome)
        _ = await coordinator.retry()
        _ = await coordinator.retry()
        XCTAssertTrue(coordinator.copyTranscript())

        guard case .awaitingUser(let pending, _) = coordinator.state else {
            return XCTFail("Expected pending recovery state")
        }
        XCTAssertEqual(pending.outcome.retryBuffer.samples, outcome.retryBuffer.samples)
        XCTAssertEqual(pending.recording.fileName, outcome.fileName)
        XCTAssertEqual(environment.copiedTexts, [outcome.text])
    }

    func testErrorClassificationRecognizesDiskFullVariants() {
        let cocoa = RecordingStorageError.classify(CocoaError(.fileWriteOutOfSpace))
        let posix = RecordingStorageError.classify(POSIXError(.ENOSPC))
        let sqlite = RecordingStorageError.classify(DatabaseError(resultCode: .SQLITE_FULL))
        let generic = RecordingStorageError.classify(SaveTestError.failure)

        XCTAssertEqual(cocoa.category, .outOfSpace)
        XCTAssertEqual(posix.category, .outOfSpace)
        XCTAssertEqual(sqlite.category, .outOfSpace)
        XCTAssertEqual(generic.category, .saveFailed)
    }

    func testExclusiveInstallDoesNotOverwriteUnownedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExclusiveInstallTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stagedURL = directory.appendingPathComponent("staged.m4a")
        let finalURL = directory.appendingPathComponent("final.m4a")
        try Data("new".utf8).write(to: stagedURL)
        try Data("existing".utf8).write(to: finalURL)

        XCTAssertThrowsError(try RecordingFileInstaller.install(
            stagedURL: stagedURL,
            finalURL: finalURL,
            replacingOwnedFile: false
        ))
        XCTAssertEqual(try Data(contentsOf: finalURL), Data("existing".utf8))
    }

    func testDatabaseFailureTracksOwnedOrphanAndCancelRemovesIt() async throws {
        let environment = try SaveEnvironment()
        defer { environment.cleanup() }
        environment.persistFailuresRemaining = 1
        let outcome = makeOutcome(audioURL: nil, storageError: SaveTestError.failure)
        let coordinator = RecordingSaveCoordinator(dependencies: environment.dependencies())

        let recording = await coordinator.save(outcome)
        XCTAssertNil(recording)
        let finalURL = environment.directory.appendingPathComponent(outcome.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))

        let cancelStarted = expectation(description: "cancel database check started")
        let cancelGate = AsyncGate()
        environment.containsRecordingOverride = { _ in
            cancelStarted.fulfill()
            await cancelGate.wait()
            return false
        }
        let cancelTask = Task { await coordinator.cancelPendingSave() }
        await fulfillment(of: [cancelStarted], timeout: 1)
        guard case .cancelling = coordinator.state else {
            return XCTFail("Expected cancelling state")
        }
        let retryDuringCancel = await coordinator.retry()
        XCTAssertNil(retryDuringCancel)
        await cancelGate.open()
        await cancelTask.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertTrue(coordinator.isIdle)
    }

    func testDatabaseInsertReportedFailureReconcilesAsSuccess() async throws {
        let environment = try SaveEnvironment()
        defer { environment.cleanup() }
        environment.persistAfterInsertFailuresRemaining = 1
        let outcome = makeOutcome(audioURL: nil, storageError: SaveTestError.failure)
        let coordinator = RecordingSaveCoordinator(dependencies: environment.dependencies())

        let recording = await coordinator.save(outcome)
        XCTAssertNotNil(recording)
        XCTAssertEqual(environment.persistCallCount, 1)
        XCTAssertTrue(coordinator.isIdle)
    }

    private func makeOutcome(
        audioURL: URL?,
        storageError: Error? = nil,
        retryBuffer: PCMRetryBuffer? = nil,
        duration: TimeInterval = 2
    ) -> StreamingCaptureOutcome {
        var defaultBuffer = PCMRetryBuffer()
        defaultBuffer.append([0.1, 0.2, 0.3, 0.4])
        let id = UUID()
        return StreamingCaptureOutcome(
            text: "final transcript",
            duration: duration,
            audioURL: audioURL,
            storageError: storageError.map(RecordingStorageError.classify),
            retryBuffer: retryBuffer ?? defaultBuffer,
            recordingID: id,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            fileName: "1700000000000-\(id.uuidString.suffix(4).lowercased()).m4a"
        )
    }
}

private enum SaveTestError: Error {
    case failure
}

private final class SaveEnvironment {
    let directory: URL
    let useRealCodec: Bool
    var encodeFailuresRemaining = 0
    var persistFailuresRemaining = 0
    var persistAfterInsertFailuresRemaining = 0
    var encodedSampleCounts: [Int] = []
    var persistCallCount = 0
    var storedIDs = Set<UUID>()
    var copiedTexts: [String] = []
    var containsRecordingOverride: ((UUID) async throws -> Bool)?
    var copySucceeds = true
    var installFailuresRemaining = 0
    var installCallCount = 0
    var removeFailuresRemaining = 0

    init(useRealCodec: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingSaveCoordinatorTests-\(UUID().uuidString)")
        self.useRealCodec = useRealCodec
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".pending"),
            withIntermediateDirectories: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    func dependencies() -> RecordingSaveDependencies {
        RecordingSaveDependencies(
            recordingsDirectory: directory,
            stagingDirectory: directory.appendingPathComponent(".pending"),
            encode: { [self] buffer, url in
                encodedSampleCounts.append(buffer.count)
                if encodeFailuresRemaining > 0 {
                    encodeFailuresRemaining -= 1
                    throw SaveTestError.failure
                }
                if useRealCodec {
                    try RecordingRetryEncoder.encode(buffer, to: url)
                } else {
                    try Data("encoded".utf8).write(to: url)
                }
            },
            validate: { [self] url, duration in
                if useRealCodec {
                    try RecordingM4AValidator.validate(url: url, expectedDuration: duration)
                } else if !FileManager.default.fileExists(atPath: url.path) {
                    throw SaveTestError.failure
                }
            },
            install: { [self] stagedURL, finalURL, replacingOwnedFile in
                installCallCount += 1
                if installFailuresRemaining > 0 {
                    installFailuresRemaining -= 1
                    throw SaveTestError.failure
                }
                try RecordingFileInstaller.install(
                    stagedURL: stagedURL,
                    finalURL: finalURL,
                    replacingOwnedFile: replacingOwnedFile
                )
            },
            persist: { [self] recording in
                persistCallCount += 1
                if persistAfterInsertFailuresRemaining > 0 {
                    persistAfterInsertFailuresRemaining -= 1
                    storedIDs.insert(recording.id)
                    throw SaveTestError.failure
                }
                if persistFailuresRemaining > 0 {
                    persistFailuresRemaining -= 1
                    throw SaveTestError.failure
                }
                storedIDs.insert(recording.id)
            },
            deleteRecording: { [self] recording in
                storedIDs.remove(recording.id)
            },
            containsRecording: { [self] id in
                if let containsRecordingOverride {
                    return try await containsRecordingOverride(id)
                }
                return storedIDs.contains(id)
            },
            isFileNameTaken: { [self] fileName in
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(fileName).path
                )
            },
            removeFile: { [self] url in
                if removeFailuresRemaining > 0 {
                    removeFailuresRemaining -= 1
                    throw SaveTestError.failure
                }
                try FileManager.default.removeItem(at: url)
            },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            copyText: { [self] text in
                guard copySucceeds else { return false }
                copiedTexts.append(text)
                return true
            }
        )
    }
}

@MainActor
final class RecordingSaveCoordinatorDirectFileTests: XCTestCase {

    func testDirectFileSaveInstallsExistingM4AWithoutEncoding() async throws {
        let environment = try SaveEnvironment()
        defer { environment.cleanup() }
        let request = try makeRequest(environment: environment)
        let coordinator = RecordingSaveCoordinator(dependencies: environment.dependencies())

        XCTAssertTrue(coordinator.reserveSave())
        let recording = await coordinator.saveReservedEncodedRecording(request)

        XCTAssertNotNil(recording)
        XCTAssertTrue(environment.encodedSampleCounts.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: environment.directory.appendingPathComponent(request.fileName).path
        ))
    }

    func testDirectFileInstallFailureRetainsSourceForRetry() async throws {
        let environment = try SaveEnvironment()
        defer { environment.cleanup() }
        environment.installFailuresRemaining = 1
        let request = try makeRequest(environment: environment)
        let coordinator = RecordingSaveCoordinator(dependencies: environment.dependencies())

        let initialRecording = await coordinator.saveEncodedRecording(request)
        XCTAssertNil(initialRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.audioURL.path))
        let foreignURL = environment.directory.appendingPathComponent(request.fileName)
        try Data("foreign".utf8).write(to: foreignURL)

        let recording = await coordinator.retry()
        XCTAssertNotNil(recording)
        XCTAssertNotEqual(recording?.fileName, request.fileName)
        XCTAssertEqual(try Data(contentsOf: foreignURL), Data("foreign".utf8))
        XCTAssertTrue(environment.encodedSampleCounts.isEmpty)
    }

    func testDirectFileDatabaseRetryDoesNotReencodeOrReinstall() async throws {
        let environment = try SaveEnvironment()
        defer { environment.cleanup() }
        environment.persistFailuresRemaining = 1
        let request = try makeRequest(environment: environment)
        let coordinator = RecordingSaveCoordinator(dependencies: environment.dependencies())

        let initialRecording = await coordinator.saveEncodedRecording(request)
        XCTAssertNil(initialRecording)
        XCTAssertEqual(environment.installCallCount, 1)

        let recording = await coordinator.retry()
        XCTAssertNotNil(recording)
        XCTAssertEqual(environment.installCallCount, 1)
        XCTAssertTrue(environment.encodedSampleCounts.isEmpty)
    }

    func testDirectFileCancelRetainsRecoveryWhenSourceDeletionFails() async throws {
        let environment = try SaveEnvironment()
        defer { environment.cleanup() }
        environment.installFailuresRemaining = 1
        let request = try makeRequest(environment: environment)
        let coordinator = RecordingSaveCoordinator(dependencies: environment.dependencies())

        let initialRecording = await coordinator.saveEncodedRecording(request)
        XCTAssertNil(initialRecording)
        environment.removeFailuresRemaining = 1

        await coordinator.cancelPendingSave()

        XCTAssertTrue(coordinator.hasPendingSave)
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.audioURL.path))
    }

    func testCancelDeletesAmbiguouslyPersistedRowAndOwnedAudio() async throws {
        let environment = try SaveEnvironment()
        defer { environment.cleanup() }
        environment.persistFailuresRemaining = 1
        let request = try makeRequest(environment: environment)
        let coordinator = RecordingSaveCoordinator(dependencies: environment.dependencies())

        let initialRecording = await coordinator.saveEncodedRecording(request)
        XCTAssertNil(initialRecording)
        environment.storedIDs.insert(request.recordingID)

        await coordinator.cancelPendingSave()

        XCTAssertFalse(environment.storedIDs.contains(request.recordingID))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: environment.directory.appendingPathComponent(request.fileName).path
        ))
        XCTAssertTrue(coordinator.isIdle)
    }

    private func makeRequest(environment: SaveEnvironment) throws -> EncodedRecordingSaveRequest {
        let id = UUID()
        let url = environment.directory.appendingPathComponent("source-\(id).m4a")
        try Data("encoded".utf8).write(to: url)
        return EncodedRecordingSaveRequest(
            text: "direct transcript",
            duration: 2,
            audioURL: url,
            recordingID: id,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            fileName: "1700000000000-\(id.uuidString.suffix(4).lowercased()).m4a"
        )
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
