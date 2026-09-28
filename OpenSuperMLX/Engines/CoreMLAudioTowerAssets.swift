// CoreMLAudioTowerAssets.swift
// OpenSuperMLX

import Foundation

/// The compiled Core ML audio tower for the Neural Engine, downloaded on first use.
enum CoreMLAudioTowerAssets {
    static let repositoryID = "axot/Qwen3-ASR-1.7B-CoreML-INT8"
    static let modelName = "qwen3_asr_audio_tower_int8.mlmodelc"
    static let modelFiles = [
        "analytics/coremldata.bin",
        "coremldata.bin",
        "metadata.json",
        "model.mil",
        "weights/weight.bin",
    ]

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
        fetch: (URL, URL) async throws -> Void = download
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
                try await fetch(downloadURL(for: file), destination)
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

    static func download(from remote: URL, to destination: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: remote)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw URLError(.badServerResponse)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
