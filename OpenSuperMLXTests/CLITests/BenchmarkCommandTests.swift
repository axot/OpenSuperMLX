// BenchmarkCommandTests.swift
// OpenSuperMLXTests

import XCTest

import ArgumentParser
@testable import OpenSuperMLX

final class BenchmarkCommandTests: XCTestCase {

    // MARK: - JSON Output Schema

    func testBenchmarkJSONOutputSchema() throws {
        let result = BenchmarkResult(
            file: "jfk.wav",
            language: "en",
            accuracy: BenchmarkResult.AccuracyResult(metric: "WER", score: 0.05, substitutions: 1, insertions: 0, deletions: 0),
            performance: BenchmarkResult.PerformanceResult(audioDurationS: 11.0, processingTimeS: 1.1, rtf: 0.10, speedFactor: 10.0, runs: 3, rtfStddev: 0.01),
            memory: BenchmarkResult.MemoryResult(peakTotalMB: 680, baselineMB: 120, inferenceDeltaMB: 560),
            pass: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["file"] as? String, "jfk.wav")
        XCTAssertEqual(json["language"] as? String, "en")
        XCTAssertEqual(json["pass"] as? Bool, true)

        let accuracy = json["accuracy"] as? [String: Any]
        XCTAssertNotNil(accuracy)
        XCTAssertEqual(accuracy?["metric"] as? String, "WER")
        XCTAssertEqual(accuracy?["score"] as? Double, 0.05)
        XCTAssertEqual(accuracy?["substitutions"] as? Int, 1)
        XCTAssertEqual(accuracy?["insertions"] as? Int, 0)
        XCTAssertEqual(accuracy?["deletions"] as? Int, 0)

        let performance = json["performance"] as? [String: Any]
        XCTAssertNotNil(performance)
        XCTAssertEqual(performance?["audio_duration_s"] as? Double, 11.0)
        XCTAssertEqual(performance?["processing_time_s"] as? Double, 1.1)
        XCTAssertEqual(performance?["rtf"] as? Double, 0.10)
        XCTAssertEqual(performance?["speed_factor"] as? Double, 10.0)
        XCTAssertEqual(performance?["runs"] as? Int, 3)
        XCTAssertEqual(performance?["rtf_stddev"] as? Double, 0.01)

        let memory = json["memory"] as? [String: Any]
        XCTAssertNotNil(memory)
        XCTAssertEqual(memory?["peak_total_mb"] as? UInt64, 680)
        XCTAssertEqual(memory?["baseline_mb"] as? UInt64, 120)
        XCTAssertEqual(memory?["inference_delta_mb"] as? UInt64, 560)
    }

    // MARK: - Option Parsing

    func testBenchmarkWERThresholdOption() throws {
        let command = try BenchmarkCommand.parse(["jfk.wav", "--wer-threshold", "0.1"])
        XCTAssertEqual(command.werThreshold, 0.1)
    }

    func testBenchmarkRunsOption() throws {
        let command = try BenchmarkCommand.parse(["jfk.wav", "--runs", "5"])
        XCTAssertEqual(command.runs, 5)
    }

    func testBenchmarkDefaultValues() throws {
        let command = try BenchmarkCommand.parse(["test.wav"])
        XCTAssertEqual(command.runs, 3)
        XCTAssertNil(command.werThreshold)
        XCTAssertNil(command.referenceText)
    }

    func testBenchmarkReferenceTextOption() throws {
        let command = try BenchmarkCommand.parse(["test.wav", "--reference-text", "hello world"])
        XCTAssertEqual(command.referenceText, "hello world")
    }

    // MARK: - Memory Measurement

    func testGetPhysFootprintReturnsNonZero() {
        let footprint = BenchmarkCommand.getPhysFootprint()
        XCTAssertGreaterThan(footprint, 0)
    }
}
