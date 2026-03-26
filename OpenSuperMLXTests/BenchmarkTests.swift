// BenchmarkTests.swift
// OpenSuperMLXTests

import XCTest

import MLX
import MLXAudioCore
import MLXAudioSTT
import HuggingFace
@testable import OpenSuperMLX

final class BenchmarkTests: XCTestCase {

    // MARK: - Constants

    private static let modelRepoID = "mlx-community/Qwen3-ASR-1.7B-8bit"
    private static let modelDirName = "models--mlx-community--Qwen3-ASR-1.7B-8bit"

    private static let jfkGroundTruth =
        "And so my fellow Americans, ask not what your country can do for you, ask what you can do for your country."

    // MARK: - Helpers

    @MainActor
    private func requireModel() throws -> URL {
        let modelDir = MLXModelManager.modelsDirectory
            .appendingPathComponent(Self.modelDirName)
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw XCTSkip("Qwen3-ASR-1.7B-8bit not downloaded — skipping benchmark")
        }
        return modelDir
    }

    private func loadModel() async throws -> Qwen3ASRModel {
        let cache = await HubCache(cacheDirectory: MLXModelManager.modelsDirectory)
        return try await Qwen3ASRModel.fromPretrained(Self.modelRepoID, cache: cache)
    }

    private func loadJFKAudio() throws -> MLXArray {
        guard let audioURL = TestFixtures.audioURL(named: "jfk") else {
            throw XCTSkip("jfk.wav not found in test bundle")
        }
        let (_, audio) = try loadAudioArray(from: audioURL, sampleRate: 16000)
        return audio
    }

    private func transcribe(model: Qwen3ASRModel, audio: MLXArray) -> STTOutput {
        model.generate(audio: audio, language: "English")
    }

    // MARK: - Baseline

    private struct Baseline: Codable {
        let model: String
        let device: String
        let date: String
        let latencyMedianSec: Double
        let memoryPeakDeltaMb: Double
        let werEnglishJfk: Double
        let thresholds: Thresholds

        struct Thresholds: Codable {
            let latencyTolerance: Double
            let memoryTolerance: Double
            let werTolerancePp: Double

            enum CodingKeys: String, CodingKey {
                case latencyTolerance = "latency_tolerance"
                case memoryTolerance = "memory_tolerance"
                case werTolerancePp = "wer_tolerance_pp"
            }
        }

        enum CodingKeys: String, CodingKey {
            case model, device, date
            case latencyMedianSec = "latency_median_sec"
            case memoryPeakDeltaMb = "memory_peak_delta_mb"
            case werEnglishJfk = "wer_english_jfk"
            case thresholds
        }
    }

    private func loadBaseline() -> Baseline? {
        let projectRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let baselinePath = projectRoot.appendingPathComponent("docs/benchmarks/baseline.json")
        guard let data = try? Data(contentsOf: baselinePath) else { return nil }
        return try? JSONDecoder().decode(Baseline.self, from: data)
    }

    // MARK: - Latency

    func testTranscriptionLatency() async throws {
        _ = try await requireModel()
        let audio = try loadJFKAudio()
        let model = try await loadModel()

        // Warmup
        _ = transcribe(model: model, audio: audio)
        Memory.clearCache()

        var latencies: [Double] = []
        for _ in 0..<3 {
            let start = Date()
            let output = transcribe(model: model, audio: audio)
            let elapsed = Date().timeIntervalSince(start)
            latencies.append(output.totalTime > 0 ? output.totalTime : elapsed)
            Memory.clearCache()
        }

        latencies.sort()
        let median = latencies[1]
        NSLog("BenchmarkTests: transcription latency median = %.3fs (runs: %@)",
              median, latencies.map { String(format: "%.3f", $0) }.joined(separator: ", "))

        if let baseline = loadBaseline() {
            let threshold = baseline.latencyMedianSec * baseline.thresholds.latencyTolerance
            XCTAssertLessThan(median, threshold,
                "Latency \(String(format: "%.3f", median))s exceeds threshold \(String(format: "%.3f", threshold))s")
        }
    }

    // MARK: - Memory

    func testPeakMemoryDuringTranscription() async throws {
        _ = try await requireModel()
        let audio = try loadJFKAudio()
        let model = try await loadModel()

        // Warmup to stabilize allocations
        _ = transcribe(model: model, audio: audio)
        Memory.clearCache()

        GPU.resetPeakMemory()
        let memoryBefore = Memory.peakMemory

        _ = transcribe(model: model, audio: audio)

        let peakBytes = Memory.peakMemory
        let deltaMB = Double(peakBytes - memoryBefore) / 1_048_576.0
        let peakMB = Double(peakBytes) / 1_048_576.0

        NSLog("BenchmarkTests: peak memory = %.1f MB, delta = %.1f MB", peakMB, deltaMB)

        Memory.clearCache()

        if let baseline = loadBaseline() {
            let threshold = baseline.memoryPeakDeltaMb * baseline.thresholds.memoryTolerance
            XCTAssertLessThan(deltaMB, threshold,
                "Memory delta \(String(format: "%.1f", deltaMB)) MB exceeds threshold \(String(format: "%.1f", threshold)) MB")
        }
    }

    // MARK: - Accuracy

    func testTranscriptionAccuracy_English() async throws {
        _ = try await requireModel()
        let audio = try loadJFKAudio()
        let model = try await loadModel()

        let output = transcribe(model: model, audio: audio)
        Memory.clearCache()

        let text = output.text
        XCTAssertTrue(text.lowercased().contains("country"),
            "Transcription should contain 'country', got: \(text)")

        let wer = WERCalculator.computeWER(reference: Self.jfkGroundTruth, hypothesis: text)
        NSLog("BenchmarkTests: WER = %.4f, text = %@", wer, text)

        XCTAssertLessThan(wer, 0.5, "WER \(wer) is unreasonably high — transcription likely failed")

        if let baseline = loadBaseline() {
            let threshold = baseline.werEnglishJfk + baseline.thresholds.werTolerancePp
            XCTAssertLessThanOrEqual(wer, threshold,
                "WER \(String(format: "%.4f", wer)) exceeds threshold \(String(format: "%.4f", threshold))")
        }
    }

    // MARK: - Language Detection

    func testAutoLanguageDetection_English() async throws {
        _ = try await requireModel()
        let audio = try loadJFKAudio()
        let model = try await loadModel()

        let output = model.generate(audio: audio, language: "auto")
        Memory.clearCache()

        guard let detectedLanguage = output.language else {
            throw XCTSkip("STTOutput.language not populated — language detection not exposed")
        }

        let langLower = detectedLanguage.lowercased()
        XCTAssertTrue(langLower.contains("en") || langLower.contains("english"),
            "Expected English, detected: \(detectedLanguage)")
    }
}
