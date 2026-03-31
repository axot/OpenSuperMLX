// SystemAudioService.swift
// OpenSuperMLX

import CoreMedia
import Foundation
import ScreenCaptureKit
import os.log

private let logger = Logger(subsystem: "OpenSuperMLX", category: "SystemAudioService")

// MARK: - SystemAudioService

final class SystemAudioService: NSObject {
    static let shared = SystemAudioService()

    private(set) var isCapturing = false
    private var stream: SCStream?

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

    // MARK: - Capture Lifecycle

    func startCapture() async throws {
        guard !isCapturing else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            logger.error("No display available for system audio capture")
            throw SystemAudioCaptureError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = makeStreamConfiguration()

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()

        self.stream = stream
        isCapturing = true
        logger.info("System audio capture started")
    }

    func stopCapture() async throws {
        guard isCapturing, let stream else { return }

        try await stream.stopCapture()
        self.stream = nil
        isCapturing = false
        logger.info("System audio capture stopped")
    }

    // MARK: - Sample Conversion

    func extractFloatSamples(from sampleBuffer: CMSampleBuffer?) -> [Float] {
        guard let sampleBuffer else { return [] }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            logger.warning("No data buffer in CMSampleBuffer")
            return []
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard status == kCMBlockBufferNoErr, let dataPointer else {
            logger.warning("Failed to get data pointer from block buffer: \(status)")
            return []
        }

        let floatCount = length / MemoryLayout<Float>.size
        let floatPointer = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: floatCount)
        let samples = Array(UnsafeBufferPointer(start: floatPointer, count: floatCount))

        logger.debug("Extracted \(samples.count) float samples from system audio buffer")
        return samples
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        logger.error("System audio stream stopped with error: \(error.localizedDescription)")
        Task { @MainActor in
            self.isCapturing = false
            self.stream = nil
        }
    }
}

// MARK: - SCStreamOutput

extension SystemAudioService: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        let samples = extractFloatSamples(from: sampleBuffer)
        if !samples.isEmpty {
            logger.debug("Received system audio buffer: \(samples.count) samples")
        }
    }
}

// MARK: - SystemAudioCaptureError

enum SystemAudioCaptureError: Error {
    case noDisplayAvailable
    case captureNotSupported
}
