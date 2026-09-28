// CoreMLAudioTowerAssets.swift
// OpenSuperMLX

import Foundation
import os

enum CoreMLAudioTowerAssets {
    static let repositoryID = "ax0t/Qwen3-ASR-1.7B-CoreML-INT8"
    static let modelName = "qwen3_asr_audio_tower_int8.mlmodelc"
    static let modelFiles = [
        "analytics/coremldata.bin",
        "coremldata.bin",
        "metadata.json",
        "model.mil",
        "weights/weight.bin",
    ]

    typealias ProgressHandler = @Sendable @MainActor (Progress) -> Void

    static var installDirectory: URL {
        installDirectory(in: MLXModelManager.modelsDirectory)
    }

    static func installDirectory(in modelsDirectory: URL) -> URL {
        modelsDirectory.appendingPathComponent("coreml")
    }

    static func downloadURL(for file: String) -> URL {
        URL(string: "https://huggingface.co/\(repositoryID)/resolve/main/\(modelName)/\(file)")!
    }

    static func isInstalled(at modelURL: URL) -> Bool {
        modelFiles.allSatisfy { file in
            let values = try? modelURL.appendingPathComponent(file).resourceValues(forKeys: [.fileSizeKey])
            return (values?.fileSize ?? 0) > 0
        }
    }

    /// Returns the installed model, downloading it into a staging directory first so an
    /// interrupted download never leaves a partial model in place.
    static func resolve(
        in directory: URL = installDirectory,
        progressHandler: ProgressHandler? = nil,
        fetch: (URL, URL, ProgressHandler?) async throws -> Void = download
    ) async throws -> URL {
        let modelURL = directory.appendingPathComponent(modelName)
        if isInstalled(at: modelURL) {
            return modelURL
        }

        let staging = directory.appendingPathComponent("\(modelName).partial-\(UUID().uuidString)")
        do {
            for file in modelFiles {
                let destination = staging.appendingPathComponent(file)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try await fetch(downloadURL(for: file), destination, progressHandler)
            }
            guard isInstalled(at: staging) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try? FileManager.default.removeItem(at: modelURL)
            try FileManager.default.moveItem(at: staging, to: modelURL)
            return modelURL
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Reports the file's byte progress every 200 ms, like the MLX model download, and once when done.
    static func download(from remote: URL, to destination: URL, progressHandler: ProgressHandler?) async throws {
        let observer = DownloadTaskObserver()
        let reporting = progressHandler.map { handler in
            Task {
                while !Task.isCancelled {
                    if let progress = observer.updatedProgress() {
                        await handler(progress)
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        defer { reporting?.cancel() }

        let (temporary, response) = try await URLSession.shared.download(from: remote, delegate: observer)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw URLError(.badServerResponse)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        if let progressHandler, let progress = observer.updatedProgress() {
            await progressHandler(progress)
        }
    }
}

// MARK: - Download Progress

/// Counts the bytes of the task that `URLSession.download(from:delegate:)` creates. That task's own
/// `progress` lags far behind the bytes received, and the async API never calls `didWriteData`.
private final class DownloadTaskObserver: NSObject, URLSessionTaskDelegate, Sendable {
    private let task = OSAllocatedUnfairLock<URLSessionTask?>(initialState: nil)
    private let progress = Progress(totalUnitCount: -1)

    func updatedProgress() -> Progress? {
        guard let task = task.withLock({ $0 }) else { return nil }
        if task.countOfBytesExpectedToReceive > 0 {
            progress.totalUnitCount = task.countOfBytesExpectedToReceive
        }
        progress.completedUnitCount = task.countOfBytesReceived
        return progress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        self.task.withLock { $0 = task }
    }
}
