// SystemAudioService.swift
// OpenSuperMLX

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import os.log

private let logger = Logger(subsystem: "OpenSuperMLX", category: "SystemAudioService")

// MARK: - SystemAudioService

@MainActor
final class SystemAudioService: NSObject, ObservableObject {
    static let shared = SystemAudioService()

    @Published private(set) var isCapturing = false

    private var stream: SCStream?
    private let accumulatedSamples = OSAllocatedUnfairLock(initialState: [Float]())

    private override init() {
        super.init()
    }

    // MARK: - Configuration

    func makeStreamConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1

        // Minimize video overhead — ScreenCaptureKit requires a display but we only want audio
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        return config
    }

    // MARK: - Content Filter

    func makeContentFilter(bundleID: String?, content: SCShareableContent) throws -> SCContentFilter {
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayAvailable
        }

        if let bundleID {
            guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
                throw SystemAudioCaptureError.applicationNotFound(bundleID)
            }
            return SCContentFilter(display: display, including: [app], exceptingWindows: [])
        }

        return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    }

    // MARK: - Capture Lifecycle

    func startCapture(bundleID: String? = nil) async throws {
        guard !isCapturing else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter = try makeContentFilter(bundleID: bundleID, content: content)
        let config = makeStreamConfiguration()

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))

        accumulatedSamples.withLock { $0.removeAll() }

        try await stream.startCapture()
        self.stream = stream
        isCapturing = true
        logger.info("System audio capture started (bundleID: \(bundleID ?? "all", privacy: .public))")
    }

    func stopCapture() async -> URL? {
        guard isCapturing, let stream else { return nil }

        do {
            try await stream.stopCapture()
        } catch {
            logger.error("Failed to stop system audio stream: \(error.localizedDescription, privacy: .public)")
        }

        self.stream = nil
        isCapturing = false

        let samples = accumulatedSamples.withLock { buf -> [Float] in
            let result = buf
            buf.removeAll()
            return result
        }

        guard !samples.isEmpty else {
            logger.info("System audio capture stopped — no samples captured")
            return nil
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("system_audio_\(Date().timeIntervalSince1970).wav")

        do {
            try writeSamplesToWAV(samples, url: url)
            logger.info("System audio capture stopped, WAV at: \(url.lastPathComponent, privacy: .public)")
            return url
        } catch {
            logger.error("Failed to write system audio WAV: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - WAV Writing

    private func writeSamplesToWAV(_ samples: [Float], url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw SystemAudioCaptureError.audioFileWriteFailed
        }

        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw SystemAudioCaptureError.audioFileWriteFailed
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        try audioFile.write(from: buffer)
    }

    // MARK: - Sample Conversion

    nonisolated func extractFloatSamples(from sampleBuffer: CMSampleBuffer?) -> [Float] {
        guard let sampleBuffer else { return [] }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            logger.warning("No data buffer in CMSampleBuffer")
            return []
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let dataPointer else {
            logger.warning("Failed to get data pointer from block buffer: \(status)")
            return []
        }

        let floatCount = length / MemoryLayout<Float>.size
        let floatPointer = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: floatCount)
        return Array(UnsafeBufferPointer(start: floatPointer, count: floatCount))
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioService: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        logger.error("System audio stream stopped with error: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in
            self.isCapturing = false
            self.stream = nil
        }
    }
}

// MARK: - SCStreamOutput

extension SystemAudioService: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }

        let samples = extractFloatSamples(from: sampleBuffer)
        if !samples.isEmpty {
            accumulatedSamples.withLock { $0.append(contentsOf: samples) }
        }
    }
}

// MARK: - SystemAudioCaptureError

enum SystemAudioCaptureError: Error {
    case noDisplayAvailable
    case captureNotSupported
    case applicationNotFound(String)
    case audioFileWriteFailed
}
