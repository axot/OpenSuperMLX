// RecordingSaveCoordinator.swift
// OpenSuperMLX

import AppKit
import AVFoundation
import Combine
import Foundation
import os

import GRDB

enum RecordingStorageErrorCategory: Equatable {
    case outOfSpace
    case saveFailed
}

struct RecordingStorageError: Error {
    let category: RecordingStorageErrorCategory
    let underlyingError: Error

    static func classify(_ error: Error) -> RecordingStorageError {
        if let storageError = error as? RecordingStorageError {
            return storageError
        }
        if let cocoaError = error as? CocoaError,
           cocoaError.code == .fileWriteOutOfSpace {
            return RecordingStorageError(category: .outOfSpace, underlyingError: error)
        }
        if let posixError = error as? POSIXError,
           posixError.code == .ENOSPC {
            return RecordingStorageError(category: .outOfSpace, underlyingError: error)
        }
        if let databaseError = error as? DatabaseError,
           databaseError.resultCode == .SQLITE_FULL {
            return RecordingStorageError(category: .outOfSpace, underlyingError: error)
        }
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            let classified = classify(underlying)
            if classified.category == .outOfSpace {
                return RecordingStorageError(category: .outOfSpace, underlyingError: error)
            }
        }
        return RecordingStorageError(category: .saveFailed, underlyingError: error)
    }
}

struct PendingRecordingSave {
    var outcome: StreamingCaptureOutcome
    var recording: Recording
    var retrySource: RecordingRetrySource
    var ownsFinalFile = false
}

enum RecordingRetrySource {
    case pcm(PCMRetryBuffer)
    case encodedFile(URL)
}

struct EncodedRecordingSaveRequest {
    let text: String
    let duration: TimeInterval
    let audioURL: URL
    let recordingID: UUID
    let timestamp: Date
    let fileName: String
}

enum RecordingSaveState {
    case idle
    case saving
    case awaitingUser(PendingRecordingSave, RecordingStorageError)
    case retrying(PendingRecordingSave)
    case cancelling(PendingRecordingSave)
}

struct RecordingSaveDependencies {
    let recordingsDirectory: URL
    let stagingDirectory: URL
    let encode: (PCMRetryBuffer, URL) async throws -> Void
    let validate: (URL, TimeInterval?) throws -> Void
    let install: (URL, URL, Bool) throws -> Void
    let persist: (Recording) async throws -> Void
    let deleteRecording: (Recording) async throws -> Void
    let containsRecording: (UUID) async throws -> Bool
    let isFileNameTaken: (String) async throws -> Bool
    let removeFile: (URL) throws -> Void
    let fileExists: (URL) -> Bool
    let copyText: (String) -> Bool

    @MainActor
    static func live() -> RecordingSaveDependencies {
        RecordingSaveDependencies(
            recordingsDirectory: Recording.recordingsDirectory,
            stagingDirectory: Recording.pendingRecordingsDirectory,
            encode: { buffer, url in
                try await Task.detached(priority: .userInitiated) {
                    try RecordingRetryEncoder.encode(buffer, to: url)
                }.value
            },
            validate: { url, duration in
                #if DEBUG
                if DevConfig.shared.forceRecordingSaveFailure {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                #endif
                try RecordingM4AValidator.validate(url: url, expectedDuration: duration)
            },
            install: RecordingFileInstaller.install,
            persist: { try await RecordingStore.shared.addRecordingSync($0) },
            deleteRecording: { try await RecordingStore.shared.deleteRecordingSync($0) },
            containsRecording: { try await RecordingStore.shared.recordingExists($0) },
            isFileNameTaken: { fileName in
                if FileManager.default.fileExists(
                    atPath: Recording.recordingsDirectory.appendingPathComponent(fileName).path
                ) {
                    return true
                }
                return try await RecordingStore.shared.fileNameExists(fileName)
            },
            removeFile: { try FileManager.default.removeItem(at: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            copyText: { text in
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(text, forType: .string)
            }
        )
    }
}

@MainActor
final class RecordingSaveCoordinator: ObservableObject {
    static let shared = RecordingSaveCoordinator(dependencies: .live())

    @Published private(set) var state: RecordingSaveState = .idle

    private let dependencies: RecordingSaveDependencies
    private let logger = Logger(subsystem: "OpenSuperMLX", category: "RecordingSaveCoordinator")

    var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    var hasPendingSave: Bool {
        switch state {
        case .awaitingUser, .retrying, .cancelling:
            return true
        case .idle, .saving:
            return false
        }
    }

    var blocksNewRecording: Bool { !isIdle }

    init(dependencies: RecordingSaveDependencies) {
        self.dependencies = dependencies
    }

    func reserveSave() -> Bool {
        guard isIdle else { return false }
        state = .saving
        return true
    }

    func releaseSaveReservation() {
        guard case .saving = state else { return }
        state = .idle
    }

    // idle -> saving -> idle
    //                  `-> awaitingUser -> retrying -> idle
    //                     |                `-> awaitingUser
    //                     `-> cancelling -> idle
    func save(_ outcome: StreamingCaptureOutcome) async -> Recording? {
        guard reserveSave() else { return nil }
        return await saveReserved(outcome)
    }

    func saveReserved(_ outcome: StreamingCaptureOutcome) async -> Recording? {
        guard case .saving = state else { return nil }

        return await saveReserved(
            outcome: outcome,
            retrySource: .pcm(outcome.retryBuffer)
        )
    }

    func saveEncodedRecording(_ request: EncodedRecordingSaveRequest) async -> Recording? {
        guard reserveSave() else { return nil }
        return await saveReservedEncodedRecording(request)
    }

    func saveReservedEncodedRecording(
        _ request: EncodedRecordingSaveRequest
    ) async -> Recording? {
        guard case .saving = state else { return nil }
        let outcome = StreamingCaptureOutcome(
            text: request.text,
            duration: request.duration,
            audioURL: request.audioURL,
            storageError: nil,
            retryBuffer: PCMRetryBuffer(),
            recordingID: request.recordingID,
            timestamp: request.timestamp,
            fileName: request.fileName
        )
        return await saveReserved(
            outcome: outcome,
            retrySource: .encodedFile(request.audioURL)
        )
    }

    private func saveReserved(
        outcome: StreamingCaptureOutcome,
        retrySource: RecordingRetrySource
    ) async -> Recording? {

        var pending = makePending(outcome: outcome, retrySource: retrySource)
        do {
            pending = try await allocateFileName(for: pending)
            let recording = try await attemptSave(pending: &pending, forceReencode: false)
            state = .idle
            return recording
        } catch {
            enterRecovery(pending: pending, error: error)
            return nil
        }
    }

    func retry() async -> Recording? {
        guard case .awaitingUser(var pending, _) = state else { return nil }
        state = .retrying(pending)

        do {
            if !pending.ownsFinalFile {
                pending = try await allocateFileName(for: pending)
            }
            let recording = try await attemptSave(pending: &pending, forceReencode: true)
            cleanupOriginalTemporaryFile(for: pending)
            state = .idle
            return recording
        } catch {
            enterRecovery(pending: pending, error: error)
            return nil
        }
    }

    func copyTranscript() -> Bool {
        guard case .awaitingUser(let pending, _) = state else { return false }
        return dependencies.copyText(pending.outcome.text)
    }

    func cancelPendingSave() async {
        guard case .awaitingUser(let pending, _) = state else { return }
        state = .cancelling(pending)
        let finalURL = dependencies.recordingsDirectory
            .appendingPathComponent(pending.recording.fileName)

        do {
            let hasDatabaseRow = try await dependencies.containsRecording(pending.recording.id)
            if hasDatabaseRow {
                try await dependencies.deleteRecording(pending.recording)
            }
            if pending.ownsFinalFile,
               dependencies.fileExists(finalURL) {
                try dependencies.removeFile(finalURL)
            }
            try cleanupOriginalTemporaryFileRequired(for: pending)
            state = .idle
        } catch {
            enterRecovery(pending: pending, error: error)
        }
    }

    // MARK: - Save Attempt

    private func attemptSave(
        pending: inout PendingRecordingSave,
        forceReencode: Bool
    ) async throws -> Recording {
        let finalURL = dependencies.recordingsDirectory
            .appendingPathComponent(pending.recording.fileName)
        let stagedURL: URL
        let ownsStagedURL: Bool
        let requiresInstall: Bool
        let expectedDuration: TimeInterval?

        switch pending.retrySource {
        case .pcm(let retryBuffer) where forceReencode || pending.outcome.audioURL == nil:
            stagedURL = makeStagingURL(fileName: pending.recording.fileName)
            ownsStagedURL = true
            requiresInstall = true
            expectedDuration = Double(retryBuffer.count) / RecordingAudioFormat.sampleRate
            do {
                try await dependencies.encode(retryBuffer, stagedURL)
            } catch {
                removeIfPresent(stagedURL)
                throw error
            }
        case .pcm(let retryBuffer):
            stagedURL = pending.outcome.audioURL!
            ownsStagedURL = false
            requiresInstall = true
            expectedDuration = Double(retryBuffer.count) / RecordingAudioFormat.sampleRate
        case .encodedFile where pending.ownsFinalFile:
            stagedURL = finalURL
            ownsStagedURL = false
            requiresInstall = false
            expectedDuration = nil
        case .encodedFile(let sourceURL):
            stagedURL = sourceURL
            ownsStagedURL = false
            requiresInstall = true
            expectedDuration = nil
        }

        do {
            try dependencies.validate(stagedURL, expectedDuration)
            if requiresInstall {
                try dependencies.install(stagedURL, finalURL, pending.ownsFinalFile)
                pending.ownsFinalFile = true
            }

            if !(try await dependencies.containsRecording(pending.recording.id)) {
                do {
                    try await dependencies.persist(pending.recording)
                } catch {
                    if (try? await dependencies.containsRecording(pending.recording.id)) != true {
                        throw error
                    }
                }
            }
            return pending.recording
        } catch {
            if ownsStagedURL {
                removeIfPresent(stagedURL)
            }
            throw error
        }
    }

    private func enterRecovery(pending: PendingRecordingSave, error: Error) {
        var storageError = RecordingStorageError.classify(error)
        if storageError.category == .saveFailed,
           pending.outcome.storageError?.category == .outOfSpace,
           let originalError = pending.outcome.storageError {
            storageError = originalError
        }
        logger.error("Recording save failed: \(error, privacy: .public)")
        state = .awaitingUser(pending, storageError)
    }

    // MARK: - Naming and Cleanup

    private func makePending(
        outcome: StreamingCaptureOutcome,
        retrySource: RecordingRetrySource
    ) -> PendingRecordingSave {
        PendingRecordingSave(
            outcome: outcome,
            recording: Recording(
                id: outcome.recordingID,
                timestamp: outcome.timestamp,
                fileName: outcome.fileName,
                transcription: outcome.text,
                duration: outcome.duration,
                status: .completed,
                progress: 1,
                sourceFileURL: nil
            ),
            retrySource: retrySource
        )
    }

    private func allocateFileName(
        for pending: PendingRecordingSave
    ) async throws -> PendingRecordingSave {
        var pending = pending
        var fileName = pending.recording.fileName
        while try await dependencies.isFileNameTaken(fileName) {
            fileName = RecordingAudioFormat.makeFileName(
                timestamp: pending.outcome.timestamp,
                id: UUID()
            )
        }
        guard fileName != pending.recording.fileName else { return pending }

        pending.outcome = StreamingCaptureOutcome(
            text: pending.outcome.text,
            duration: pending.outcome.duration,
            audioURL: pending.outcome.audioURL,
            storageError: pending.outcome.storageError,
            retryBuffer: pending.outcome.retryBuffer,
            recordingID: pending.outcome.recordingID,
            timestamp: pending.outcome.timestamp,
            fileName: fileName
        )
        pending.recording = Recording(
            id: pending.recording.id,
            timestamp: pending.recording.timestamp,
            fileName: fileName,
            transcription: pending.recording.transcription,
            duration: pending.recording.duration,
            status: pending.recording.status,
            progress: pending.recording.progress,
            sourceFileURL: pending.recording.sourceFileURL
        )
        return pending
    }

    private func makeStagingURL(fileName: String) -> URL {
        dependencies.stagingDirectory.appendingPathComponent(
            ".\(fileName).\(UUID().uuidString).staging.m4a"
        )
    }

    private func cleanupOriginalTemporaryFile(for pending: PendingRecordingSave) {
        guard let url = pending.outcome.audioURL else { return }
        let finalURL = dependencies.recordingsDirectory
            .appendingPathComponent(pending.recording.fileName)
        guard url != finalURL else { return }
        removeIfPresent(url)
    }

    private func cleanupOriginalTemporaryFileRequired(
        for pending: PendingRecordingSave
    ) throws {
        guard let url = pending.outcome.audioURL else { return }
        let finalURL = dependencies.recordingsDirectory
            .appendingPathComponent(pending.recording.fileName)
        guard url != finalURL, dependencies.fileExists(url) else { return }
        try dependencies.removeFile(url)
    }

    private func removeIfPresent(_ url: URL) {
        guard dependencies.fileExists(url) else { return }
        do {
            try dependencies.removeFile(url)
        } catch {
            logger.error("Failed to remove temporary recording: \(error, privacy: .public)")
        }
    }
}

enum RecordingRetryEncoder {
    static func encode(_ buffer: PCMRetryBuffer, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let writer = try AACRecordingWriter(url: url)
        do {
            let chunkSize = 16_000
            var offset = 0
            while offset < buffer.samples.count {
                let end = min(offset + chunkSize, buffer.samples.count)
                let samples = buffer.samples[offset..<end].map { sample in
                    sample == .min ? -1 : Float(sample) / Float(Int16.max)
                }
                try writer.writeChunk(samples)
                offset = end
            }
            _ = try writer.finalize()
        } catch {
            writer.cancel()
            throw error
        }
    }
}

enum RecordingM4AValidator {
    static func validate(url: URL, expectedDuration: TimeInterval?) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
              file.processingFormat.channelCount == 1,
              file.processingFormat.sampleRate == RecordingAudioFormat.sampleRate else {
            throw RecordingValidationError.invalidFormat
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite,
              duration > 0 else {
            throw RecordingValidationError.invalidDuration
        }
        if let expectedDuration,
           abs(duration - expectedDuration) > 0.15 {
            throw RecordingValidationError.invalidDuration
        }
    }
}

enum RecordingValidationError: Error {
    case invalidFormat
    case invalidDuration
}

enum RecordingFileInstaller {
    static func install(
        stagedURL: URL,
        finalURL: URL,
        replacingOwnedFile: Bool
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: finalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if replacingOwnedFile, fileManager.fileExists(atPath: finalURL.path) {
            _ = try fileManager.replaceItemAt(finalURL, withItemAt: stagedURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: finalURL)
        }
    }
}
