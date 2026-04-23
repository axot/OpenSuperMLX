// StreamingE2ETests.swift
// OpenSuperMLXTests

import AVFoundation
import XCTest

import MLX
import MLXAudioCore
import MLXAudioSTT
@testable import OpenSuperMLX

@MainActor
final class StreamingE2ETests: XCTestCase {

    // MARK: - Configuration

    private static let audioEnvVar = "OPENSUPERMLX_E2E_AUDIO"

    private var service: StreamingAudioService!

    override func setUp() async throws {
        try await super.setUp()
        executionTimeAllowance = 3600
        service = StreamingAudioService.shared
        service.clearRingBuffer()
    }

    override func tearDown() async throws {
        service.clearRingBuffer()
        service = nil
        try await super.tearDown()
    }

    // MARK: - Prerequisites

    private func requireAudioURL() throws -> URL {
        if let path = ProcessInfo.processInfo.environment[Self.audioEnvVar] {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("Audio file not found at \(path)")
            }
            return url
        }

        let fallback = NSHomeDirectory() + "/.opensupermlx-e2e-audio"
        if let path = try? String(contentsOfFile: fallback, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        throw XCTSkip("Set \(Self.audioEnvVar) env var or write audio path to ~/.opensupermlx-e2e-audio")
    }

    private func requireModel() throws {
        let mlxAudioDir = MLXModelManager.modelsDirectory
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent("mlx-community_Qwen3-ASR-1.7B-8bit")
        guard FileManager.default.fileExists(atPath: mlxAudioDir.path) else {
            throw XCTSkip("Qwen3-ASR-1.7B-8bit not downloaded — skipping E2E")
        }
    }

    private func waitForModelLoad() async throws {
        let transcriptionService = TranscriptionService.shared
        if transcriptionService.streamingModel == nil && !transcriptionService.isLoading {
            AppPreferences.shared.selectedMLXModel = "mlx-community/Qwen3-ASR-1.7B-8bit"
            transcriptionService.reloadEngine()
        }
        var waitCount = 0
        while transcriptionService.isLoading && waitCount < 120 {
            try await Task.sleep(nanoseconds: 500_000_000)
            waitCount += 1
        }
        guard transcriptionService.streamingModel != nil else {
            throw XCTSkip("Model failed to load")
        }
    }

    private func audioDuration(url: URL) throws -> Double {
        let (_, audio) = try loadAudioArray(from: url, sampleRate: 16000)
        return Double(audio.dim(0)) / 16000.0
    }

    private func truncatedAudioFile(from url: URL, maxSeconds: Double) throws -> (URL, Bool) {
        let (_, audio) = try loadAudioArray(from: url, sampleRate: 16000)
        let totalSamples = audio.dim(0)
        let maxSamples = Int(maxSeconds * 16000)
        guard totalSamples > maxSamples else { return (url, false) }

        let truncated = audio[0..<maxSamples]
        eval(truncated)
        let samples = truncated.asArray(Float.self)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e_truncated_\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)
        let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
        try file.write(from: buffer)
        return (tempURL, true)
    }

    // MARK: - Tests

    func testStreamingProducesNonEmptyText() async throws {
        try requireModel()
        let audioURL = try requireAudioURL()
        try await waitForModelLoad()

        let (testURL, isTemp) = try truncatedAudioFile(from: audioURL, maxSeconds: 30)
        defer { if isTemp { try? FileManager.default.removeItem(at: testURL) } }

        let result = try await service.injectAudioFromFile(
            url: testURL,
            language: "auto",
            chunkDuration: 0.5,
            onEvent: { _ in }
        )

        XCTAssertFalse(result.text.isEmpty, "Streaming should produce non-empty text")
        XCTAssertGreaterThan(result.chunksFed, 0, "Should have fed at least one chunk")
    }

    func testStreamingReceivesIntermediateUpdates() async throws {
        try requireModel()
        let audioURL = try requireAudioURL()
        try await waitForModelLoad()

        let (testURL, isTemp) = try truncatedAudioFile(from: audioURL, maxSeconds: 30)
        defer { if isTemp { try? FileManager.default.removeItem(at: testURL) } }

        var updateCount = 0
        let result = try await service.injectAudioFromFile(
            url: testURL,
            language: "auto",
            chunkDuration: 0.5,
            onEvent: { event in
                if case .displayUpdate = event { updateCount += 1 }
            }
        )

        XCTAssertGreaterThan(updateCount, 0, "Should receive displayUpdate events during streaming")
        XCTAssertEqual(result.intermediateUpdates, updateCount)
    }

    func testStreamingCompletesWithinTimeLimit() async throws {
        try requireModel()
        let audioURL = try requireAudioURL()
        try await waitForModelLoad()

        let (testURL, isTemp) = try truncatedAudioFile(from: audioURL, maxSeconds: 60)
        defer { if isTemp { try? FileManager.default.removeItem(at: testURL) } }

        let duration = try audioDuration(url: testURL)
        let maxAllowed = max(duration * 5, 60)

        let start = CFAbsoluteTimeGetCurrent()
        let result = try await service.injectAudioFromFile(
            url: testURL,
            language: "auto",
            chunkDuration: 0.5,
            onEvent: { _ in }
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, maxAllowed,
            "Processing took \(String(format: "%.1f", elapsed))s for \(String(format: "%.1f", duration))s audio — exceeded 5x limit")
        XCTAssertFalse(result.text.isEmpty)
    }

    func testStreamingTextGrowsOverTime() async throws {
        try requireModel()
        let audioURL = try requireAudioURL()
        try await waitForModelLoad()

        let (testURL, isTemp) = try truncatedAudioFile(from: audioURL, maxSeconds: 30)
        defer { if isTemp { try? FileManager.default.removeItem(at: testURL) } }

        var textLengths: [Int] = []
        let result = try await service.injectAudioFromFile(
            url: testURL,
            language: "auto",
            chunkDuration: 0.5,
            onEvent: { event in
                if case .displayUpdate(let confirmed, _) = event {
                    textLengths.append(confirmed.count)
                }
            }
        )

        XCTAssertFalse(result.text.isEmpty)

        let nonZero = textLengths.filter { $0 > 0 }
        XCTAssertGreaterThan(nonZero.count, 1,
            "Text should grow across multiple updates, got \(nonZero.count) non-zero update(s)")

        if let maxLen = textLengths.max() {
            XCTAssertGreaterThan(maxLen, 0, "Should have produced text during streaming")
        }
    }

    func testStreamingNoStallOnLongAudio() async throws {
        try requireModel()
        let audioURL = try requireAudioURL()
        try await waitForModelLoad()

        let duration = try audioDuration(url: audioURL)
        try XCTSkipIf(duration < 120, "Audio is \(String(format: "%.0f", duration))s — need ≥2min for long-duration test")

        var updateCount = 0
        var lastConfirmedTextLength = 0
        var textGrowthCount = 0

        let result = try await service.injectAudioFromFile(
            url: audioURL,
            language: "auto",
            chunkDuration: 0.5,
            onEvent: { event in
                if case .displayUpdate(let confirmed, _) = event {
                    updateCount += 1
                    if confirmed.count > lastConfirmedTextLength {
                        textGrowthCount += 1
                        lastConfirmedTextLength = confirmed.count
                    }
                }
            }
        )

        XCTAssertFalse(result.text.isEmpty, "Should produce text from long audio")
        XCTAssertGreaterThan(updateCount, 10,
            "Should receive many intermediate updates for \(String(format: "%.0f", duration))s audio, got \(updateCount)")
        XCTAssertGreaterThan(textGrowthCount, 5,
            "Text should grow at least 5 times during long audio, got \(textGrowthCount)")
    }

    func testStreamingStatsReceived() async throws {
        try requireModel()
        let audioURL = try requireAudioURL()
        try await waitForModelLoad()

        let (testURL, isTemp) = try truncatedAudioFile(from: audioURL, maxSeconds: 30)
        defer { if isTemp { try? FileManager.default.removeItem(at: testURL) } }

        var statsCount = 0
        var lastPeakMemGB: Double = 0
        let result = try await service.injectAudioFromFile(
            url: testURL,
            language: "auto",
            chunkDuration: 0.5,
            onEvent: { event in
                if case .stats(let stats) = event {
                    statsCount += 1
                    lastPeakMemGB = stats.peakMemoryGB
                }
            }
        )

        XCTAssertFalse(result.text.isEmpty)
        XCTAssertGreaterThan(statsCount, 0, "Should receive stats events")
        XCTAssertGreaterThan(lastPeakMemGB, 0, "Peak memory should be reported")
    }
}
