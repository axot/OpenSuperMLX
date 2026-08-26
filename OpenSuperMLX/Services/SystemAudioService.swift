// SystemAudioService.swift
// OpenSuperMLX

import AVFoundation
import CoreMedia
import Foundation
import os.log
import ScreenCaptureKit

private let logger = Logger(subsystem: "OpenSuperMLX", category: "SystemAudioService")

enum AudioSampleRates {
    static let transcription: Double = 16_000
    static let systemCapture: Double = 48_000
}

// MARK: - SystemAudioService

@MainActor
final class SystemAudioService: NSObject, ObservableObject {
    static let shared = SystemAudioService()

    @Published private(set) var isCapturing = false
    nonisolated var activeSampleRate: Double {
        activeSampleRateLock.withLock { $0 }
    }

    private var stream: SCStream?
    private let accumulatedSamples = OSAllocatedUnfairLock(initialState: [Float]())
    private let activeSampleRateLock = OSAllocatedUnfairLock(initialState: AudioSampleRates.systemCapture)
    private let audioOutputQueue = DispatchQueue(label: "OpenSuperMLX.systemAudio", qos: .userInteractive)
    private let nextExpectedAudioTime = OSAllocatedUnfairLock<CMTime?>(initialState: nil)
    private let lastObservedSampleRate = OSAllocatedUnfairLock<Double?>(initialState: nil)

    private override init() {
        super.init()
    }

    // MARK: - Configuration

    func makeStreamConfiguration(sampleRate: Double) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = 1
        setActiveSampleRate(sampleRate)
        lastObservedSampleRate.withLock { $0 = nil }

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
            // Bundle IDs are case-insensitive on macOS.
            let normalized = bundleID.lowercased()
            guard let app = content.applications.first(where: {
                $0.bundleIdentifier.lowercased() == normalized
            }) else {
                throw SystemAudioCaptureError.applicationNotFound(bundleID)
            }
            return SCContentFilter(display: display, including: [app], exceptingWindows: [])
        }

        return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    }

    // MARK: - Capture Lifecycle

    func startCapture(bundleID: String? = nil, sampleRate: Double = AudioSampleRates.systemCapture) async throws {
        guard !isCapturing else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter = try makeContentFilter(bundleID: bundleID, content: content)
        let config = makeStreamConfiguration(sampleRate: sampleRate)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioOutputQueue)

        accumulatedSamples.withLock { $0.removeAll() }
        nextExpectedAudioTime.withLock { $0 = nil }

        try await stream.startCapture()
        self.stream = stream
        isCapturing = true
        PipelineTrace.shared.log("SCK", "capture started")
        logger.info("System audio capture started (bundleID: \(bundleID ?? "all", privacy: .public))")
    }

    nonisolated func drainAccumulatedSamples() -> [Float] {
        accumulatedSamples.withLock { buffer in
            let drained = buffer
            buffer.removeAll(keepingCapacity: true)
            return drained
        }
    }

    func stopAndDrain() async -> [Float] {
        guard isCapturing, let stream else { return [] }

        do {
            try await stream.stopCapture()
        } catch {
            logger.error("Failed to stop system audio stream: \(error.localizedDescription, privacy: .public)")
        }

        self.stream = nil
        isCapturing = false
        nextExpectedAudioTime.withLock { $0 = nil }
        PipelineTrace.shared.log("SCK", "capture stopped")

        return accumulatedSamples.withLock { buf -> [Float] in
            let result = buf
            buf.removeAll()
            return result
        }
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

    nonisolated func sampleRate(from formatDescription: CMFormatDescription?) -> Double? {
        guard let formatDescription,
              CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Audio,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let sampleRate = streamDescription.pointee.mSampleRate
        return sampleRate > 0 ? sampleRate : nil
    }

    nonisolated func observedSampleRate(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let observed = sampleRate(from: CMSampleBufferGetFormatDescription(sampleBuffer)) else {
            return activeSampleRate
        }

        let previousObserved = lastObservedSampleRate.withLock { previous -> Double? in
            defer { previous = observed }
            return previous
        }

        if previousObserved != observed {
            logger.info("System audio actual sample rate: \(observed, privacy: .public)Hz")
        }

        let configured = activeSampleRate
        if abs(configured - observed) > 0.5 {
            logger.warning("System audio sample rate mismatch: configured=\(configured, privacy: .public)Hz actual=\(observed, privacy: .public)Hz; using actual rate")
            setActiveSampleRate(observed)
        }

        return observed
    }

    nonisolated private func setActiveSampleRate(_ sampleRate: Double) {
        activeSampleRateLock.withLock { $0 = sampleRate }
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
        guard type == .audio,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sampleRate = observedSampleRate(from: sampleBuffer)
        let samples = extractFloatSamples(from: sampleBuffer)

        let computedDuration = CMTime(
            value: CMTimeValue(samples.count),
            timescale: CMTimeScale(sampleRate)
        )

        let silenceSamples: [Float]? = nextExpectedAudioTime.withLock { expected in
            defer {
                if pts != .invalid {
                    expected = CMTimeAdd(pts, computedDuration)
                }
            }
            guard let exp = expected, pts != .invalid, exp != .invalid else { return nil }
            let gapSeconds = CMTimeGetSeconds(pts) - CMTimeGetSeconds(exp)
            guard gapSeconds > 0.001 else { return nil }
            let gapSampleCount = Int(gapSeconds * sampleRate)
            guard gapSampleCount > 0, gapSampleCount < Int(sampleRate) else { return nil }
            return [Float](repeating: 0, count: gapSampleCount)
        }

        if let silence = silenceSamples {
            logger.warning("[SCK-GAP] inserting \(silence.count) silence samples")
        }

        if silenceSamples != nil || !samples.isEmpty {
            accumulatedSamples.withLock { buffer in
                if let silence = silenceSamples {
                    buffer.append(contentsOf: silence)
                }
                buffer.append(contentsOf: samples)
            }
        }
    }
}

// MARK: - SystemAudioCaptureError

enum SystemAudioCaptureError: Error {
    case noDisplayAvailable
    case applicationNotFound(String)
}
