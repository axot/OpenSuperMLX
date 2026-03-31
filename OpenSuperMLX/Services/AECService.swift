// AECService.swift
// OpenSuperMLX

import AVFoundation
import Foundation
import os

import DTLNAec256
import DTLNAecCoreML

private let logger = Logger(subsystem: "OpenSuperMLX", category: "AECService")

enum AECError: Error, LocalizedError {
    case inputFileNotFound(URL)
    case processingFailed(String)
    case audioFormatError(String)

    var errorDescription: String? {
        switch self {
        case .inputFileNotFound(let url):
            "AEC input file not found: \(url.lastPathComponent)"
        case .processingFailed(let reason):
            "AEC processing failed: \(reason)"
        case .audioFormatError(let reason):
            "AEC audio format error: \(reason)"
        }
    }
}

final class AECService {
    static let shared = AECService()

    private static let sampleRate: Double = 16_000
    private static let chunkSize = 1024

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

        let micSamples = try readAudioFile(url: micTrackURL)
        let systemSamples = try readAudioFile(url: systemAudioTrackURL)

        if micSamples.isEmpty {
            return micTrackURL
        }

        return try await Task.detached(priority: .userInitiated) {
            try self.runAECPipeline(micSamples: micSamples, systemSamples: systemSamples)
        }.value
    }

    // MARK: - Pipeline

    private func runAECPipeline(micSamples: [Float], systemSamples: [Float]) throws -> URL {
        let startTime = CFAbsoluteTimeGetCurrent()

        let processor = DTLNAecEchoProcessor(modelSize: .medium)
        try processor.loadModels(from: DTLNAec256.bundle)
        processor.resetStates()

        let alignedLength = min(micSamples.count, systemSamples.count)
        var cleanedSamples: [Float] = []
        cleanedSamples.reserveCapacity(micSamples.count)

        var offset = 0
        while offset < alignedLength {
            let end = min(offset + Self.chunkSize, alignedLength)
            let sysChunk = Array(systemSamples[offset..<end])
            let micChunk = Array(micSamples[offset..<end])

            processor.feedFarEnd(sysChunk)
            let cleaned = processor.processNearEnd(micChunk)
            cleanedSamples.append(contentsOf: cleaned)

            offset = end
        }

        // Pass remaining mic samples through unprocessed (mic longer than system)
        if micSamples.count > alignedLength {
            let remaining = Array(micSamples[alignedLength...])
            let processed = processor.processNearEnd(remaining)
            cleanedSamples.append(contentsOf: processed)
        }

        let flushed = processor.flush()
        if !flushed.isEmpty {
            cleanedSamples.append(contentsOf: flushed)
        }

        let outputURL = try writeAudioFile(samples: cleanedSamples)

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let duration = Double(micSamples.count) / Self.sampleRate
        logger.info("AEC processing took \(String(format: "%.2f", elapsed))s for \(String(format: "%.2f", duration))s of audio")

        return outputURL
    }

    // MARK: - Audio I/O

    private func readAudioFile(url: URL) throws -> [Float] {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw AECError.processingFailed("Cannot read audio file: \(error.localizedDescription)")
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AECError.audioFormatError("Cannot create 16kHz mono Float32 format")
        }

        let frameCount = AVAudioFrameCount(audioFile.length)
        if frameCount == 0 {
            return []
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AECError.audioFormatError("Cannot create PCM buffer for \(frameCount) frames")
        }

        do {
            try audioFile.read(into: buffer, frameCount: frameCount)
        } catch {
            throw AECError.processingFailed("Cannot read audio data: \(error.localizedDescription)")
        }

        guard let channelData = buffer.floatChannelData else {
            throw AECError.audioFormatError("No float channel data in buffer")
        }

        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }

    private func writeAudioFile(samples: [Float]) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aec_\(UUID().uuidString).wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AECError.audioFormatError("Cannot create output format")
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw AECError.audioFormatError("Cannot create output buffer")
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData else {
            throw AECError.audioFormatError("No float channel data in output buffer")
        }

        samples.withUnsafeBufferPointer { src in
            channelData[0].update(from: src.baseAddress!, count: samples.count)
        }

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        } catch {
            throw AECError.processingFailed("Cannot create output file: \(error.localizedDescription)")
        }

        do {
            try outputFile.write(from: buffer)
        } catch {
            throw AECError.processingFailed("Cannot write output file: \(error.localizedDescription)")
        }

        return outputURL
    }
}
