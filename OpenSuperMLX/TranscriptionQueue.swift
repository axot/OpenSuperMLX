import Foundation
import AVFoundation
import Combine
import os

@MainActor
class TranscriptionQueue: ObservableObject {
    static let shared = TranscriptionQueue()

    @Published private(set) var isProcessing = false
    @Published private(set) var currentRecordingId: UUID?

    private let transcriptionService: TranscriptionService
    private let recordingStore: RecordingStore
    private let onMissingAudio: (String) -> Void
    private let logger = Logger(subsystem: "OpenSuperMLX", category: "TranscriptionQueue")
    private var processingTask: Task<Void, Never>?
    private var currentTranscriptionTask: Task<Void, Never>?
    private var cancelledRecordingIds: Set<UUID> = []
    private var progressCancellable: AnyCancellable?

    private init() {
        self.transcriptionService = TranscriptionService.shared
        self.recordingStore = RecordingStore.shared
        self.onMissingAudio = { message in
            ErrorToastManager.shared.show(message)
        }
        setupProgressObserver()
    }

    init(
        transcriptionService: TranscriptionService,
        recordingStore: RecordingStore,
        onMissingAudio: @escaping (String) -> Void = { _ in },
        observesProgress: Bool = true
    ) {
        self.transcriptionService = transcriptionService
        self.recordingStore = recordingStore
        self.onMissingAudio = onMissingAudio
        if observesProgress {
            setupProgressObserver()
        }
    }
    
    private func setupProgressObserver() {
        progressCancellable = transcriptionService.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newProgress in
                guard let self = self,
                      let recordingId = self.currentRecordingId,
                      newProgress > 0,
                      newProgress < 1.0 else { return }
                
                Task {
                    await self.recordingStore.updateRecordingStatusOnly(
                        recordingId,
                        progress: newProgress,
                        status: .transcribing
                    )
                }
            }
    }

    func cancelRecording(_ recordingId: UUID) {
        cancelledRecordingIds.insert(recordingId)

        if currentRecordingId == recordingId {
            transcriptionService.cancelTranscription()
            currentTranscriptionTask?.cancel()
        }
    }

    private func isRecordingCancelled(_ recordingId: UUID) -> Bool {
        return cancelledRecordingIds.contains(recordingId)
    }

    private func clearCancellation(_ recordingId: UUID) {
        cancelledRecordingIds.remove(recordingId)
    }

    func startProcessingQueue() {
        guard !isProcessing else { return }
        guard !StreamingAudioService.shared.isStreaming else { return }

        isProcessing = true

        processingTask = Task {
            await cleanupMissingFiles()
            await processQueue()
            isProcessing = false
            processingTask = nil
        }
    }

    private func cleanupMissingFiles() async {
        let pendingRecordings = recordingStore.getPendingRecordings()

        let missingRecordings = await Task.detached(priority: .utility) {
            var toDelete: [Recording] = []
            var toFail: [Recording] = []
            var sourceUpdates: [(id: UUID, path: String)] = []
            for recording in pendingRecordings {
                if let sourceURL = Self.resolveRegenerationSource(
                    for: recording,
                    fileExists: { FileManager.default.fileExists(atPath: $0.path) }
                ) {
                    if sourceURL.path != recording.sourceFileURL {
                        sourceUpdates.append((recording.id, sourceURL.path))
                    }
                    continue
                }

                if Self.shouldDeleteMissingPendingRecording(recording) {
                    toDelete.append(recording)
                } else {
                    toFail.append(recording)
                }
            }
            return (toDelete: toDelete, toFail: toFail, sourceUpdates: sourceUpdates)
        }.value
        
        for recording in missingRecordings.toDelete {
            recordingStore.deleteRecording(recording)
        }
        for recording in missingRecordings.toFail {
            await markFailure(recording, message: "Source file not found")
        }
        for update in missingRecordings.sourceUpdates {
            do {
                try await recordingStore.updateSourceFileURL(update.id, sourceURL: update.path)
            } catch {
                logger.error("Failed to restore stored audio source: \(error, privacy: .public)")
            }
        }
    }

    func addFileToQueue(url: URL) async {
        do {
            let durationInSeconds = await (try? Task.detached(priority: .userInitiated) {
                let asset = AVAsset(url: url)
                let duration = try await asset.load(.duration)
                return CMTimeGetSeconds(duration)
            }.value) ?? 0.0

            let timestamp = Date()
            var id = UUID()
            var fileName = RecordingAudioFormat.makeFileName(
                timestamp: timestamp,
                id: id,
                pathExtension: url.pathExtension
            )
            while try await recordingStore.fileNameExists(fileName)
                || FileManager.default.fileExists(
                    atPath: Recording.recordingsDirectory
                        .appendingPathComponent(fileName).path
                )
            {
                id = UUID()
                fileName = RecordingAudioFormat.makeFileName(
                    timestamp: timestamp,
                    id: id,
                    pathExtension: url.pathExtension
                )
            }

            let recording = Recording(
                id: id,
                timestamp: timestamp,
                fileName: fileName,
                transcription: "",
                duration: durationInSeconds,
                status: .pending,
                progress: 0.0,
                sourceFileURL: url.path
            )

            try await recordingStore.addRecordingSync(recording)

            startProcessingQueue()
        } catch {
            logger.error("Failed to add file to queue: \(error, privacy: .public)")
        }
    }

    func requeueRecording(_ recording: Recording) async {
        let sourceURL: URL? = await Task.detached(priority: .userInitiated) {
            Self.resolveRegenerationSource(
                for: recording,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) }
            )
        }.value
        
        guard let sourceURL = sourceURL else {
            await recordingStore.updateRecordingStatusOnly(
                recording.id,
                progress: 0.0,
                status: .failed,
                isRegeneration: false
            )
            onMissingAudio("Audio file not found. Original transcript was kept.")
            return
        }

        await recordingStore.updateRecordingStatusOnly(
            recording.id,
            progress: 0.0,
            status: .pending,
            isRegeneration: true
        )

        do {
            try await recordingStore.updateSourceFileURL(recording.id, sourceURL: sourceURL.path)
        } catch {
            logger.error("Failed to update source URL: \(error, privacy: .public)")
        }

        startProcessingQueue()
    }

    nonisolated static func resolveRegenerationSource(
        for recording: Recording,
        fileExists: (URL) -> Bool
    ) -> URL? {
        if let existingSource = recording.sourceFileURL,
           !existingSource.isEmpty {
            let sourceURL = URL(fileURLWithPath: existingSource)
            if fileExists(sourceURL) {
                return sourceURL
            }
        }
        return fileExists(recording.url) ? recording.url : nil
    }

    private func processQueue() async {
        while let recording = recordingStore.getNextPendingRecording() {
            currentRecordingId = recording.id
            await processRecording(recording)
            currentRecordingId = nil
        }
    }

    private func processRecording(_ recording: Recording) async {
        if isRecordingCancelled(recording.id) {
            clearCancellation(recording.id)
            return
        }

        guard let sourceURLString = recording.sourceFileURL,
              !sourceURLString.isEmpty else {
            await markFailure(recording, message: "Source file not found")
            return
        }

        let sourceURL = URL(fileURLWithPath: sourceURLString)

        let sourceExists = await Task.detached(priority: .userInitiated) {
            FileManager.default.fileExists(atPath: sourceURL.path)
        }.value
        
        guard sourceExists else {
            await markFailure(recording, message: "Source file not found")
            return
        }

        let isRegeneration = Self.hasOriginalTranscription(recording)

        if isRegeneration {
            await recordingStore.updateRecordingStatusOnly(
                recording.id,
                progress: 0.0,
                status: .converting
            )
        } else {
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "",
                progress: 0.0,
                status: .converting
            )
        }

        currentTranscriptionTask = Task {
            do {
                if isRecordingCancelled(recording.id) {
                    return
                }

                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    return
                }

                let settings = Settings()
                let text = try await transcriptionService.transcribeAudio(url: sourceURL, settings: settings)

                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    return
                }

                let finalURL = recording.url
                try await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.createDirectory(
                        at: Recording.recordingsDirectory,
                        withIntermediateDirectories: true
                    )

                    if sourceURL.path != finalURL.path {
                        if FileManager.default.fileExists(atPath: finalURL.path) {
                            try? FileManager.default.removeItem(at: finalURL)
                        }
                        try FileManager.default.copyItem(at: sourceURL, to: finalURL)
                    }
                }.value

                await recordingStore.updateRecordingProgressOnlySync(
                    recording.id,
                    transcription: text,
                    progress: 1.0,
                    status: .completed,
                    isRegeneration: false
                )

            } catch {
                if !isRecordingCancelled(recording.id) && !Task.isCancelled {
                    await markFailure(
                        recording,
                        message: "Failed to transcribe: \(error.localizedDescription)"
                    )
                }
            }
        }

        await currentTranscriptionTask?.value
        currentTranscriptionTask = nil
        clearCancellation(recording.id)
    }

    private nonisolated static func hasOriginalTranscription(_ recording: Recording) -> Bool {
        !recording.transcription.isEmpty
            && recording.transcription != "In queue..."
            && recording.transcription != "Starting transcription..."
    }

    nonisolated static func shouldDeleteMissingPendingRecording(
        _ recording: Recording
    ) -> Bool {
        !hasOriginalTranscription(recording)
    }

    private func markFailure(_ recording: Recording, message: String) async {
        if Self.hasOriginalTranscription(recording) {
            await recordingStore.updateRecordingStatusOnly(
                recording.id,
                progress: 0.0,
                status: .failed,
                isRegeneration: false
            )
        } else {
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: message,
                progress: 0.0,
                status: .failed,
                isRegeneration: false
            )
        }
    }

}
