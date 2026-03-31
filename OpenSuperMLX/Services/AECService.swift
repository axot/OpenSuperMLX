// AECService.swift
// OpenSuperMLX

import Foundation
import os

import DTLNAec256
import DTLNAecCoreML

private let logger = Logger(subsystem: "OpenSuperMLX", category: "AECService")

enum AECError: Error, LocalizedError {
    case inputFileNotFound(URL)
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .inputFileNotFound(let url):
            "AEC input file not found: \(url.lastPathComponent)"
        case .processingFailed(let reason):
            "AEC processing failed: \(reason)"
        }
    }
}

final class AECService {
    static let shared = AECService()

    var isAvailable: Bool {
        do {
            let processor = DTLNAecEchoProcessor(modelSize: .medium)
            try processor.loadModels(from: DTLNAec256.bundle)
            return true
        } catch {
            logger.warning("AEC model not available: \(error.localizedDescription)")
            return false
        }
    }

    private init() {}

    // MARK: - Processing

    func processRecording(micTrackURL: URL, systemAudioTrackURL: URL) async throws -> URL {
        guard FileManager.default.fileExists(atPath: micTrackURL.path) else {
            throw AECError.inputFileNotFound(micTrackURL)
        }
        guard FileManager.default.fileExists(atPath: systemAudioTrackURL.path) else {
            throw AECError.inputFileNotFound(systemAudioTrackURL)
        }

        // Full AEC pipeline will be implemented in Task 8
        throw AECError.processingFailed("not yet implemented")
    }
}
