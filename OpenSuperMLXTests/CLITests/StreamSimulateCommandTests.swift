// StreamSimulateCommandTests.swift
// OpenSuperMLXTests

import XCTest

import ArgumentParser
@testable import OpenSuperMLX

@MainActor
final class StreamSimulateCommandTests: XCTestCase {

    // MARK: - Argument Parsing

    func testStreamSimulateParseChunkDuration() throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(
            ["stream-simulate", "file.wav", "--chunk-duration", "0.3"]
        ) as! StreamSimulateCommand
        XCTAssertEqual(command.chunkDuration, 0.3)
        XCTAssertEqual(command.file, "file.wav")
    }

    func testStreamSimulateDefaultChunkDuration() throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(
            ["stream-simulate", "file.wav"]
        ) as! StreamSimulateCommand
        XCTAssertEqual(command.chunkDuration, 0.5)
    }

    // MARK: - Error Handling

    func testStreamSimulateNonExistentFile() async throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(
            ["stream-simulate", "/nonexistent.wav", "--json"]
        ) as! StreamSimulateCommand

        let result = await command.executeStreamSimulate(
            service: StreamingAudioService.shared
        )

        guard case .failure(let error) = result else {
            XCTFail("Expected failure for non-existent file"); return
        }
        XCTAssertEqual(error, .audioFileNotFound)
    }

    // MARK: - JSON Output Schema

    func testStreamSimulateJSONOutputSchema() throws {
        let result = StreamSimulateResult(
            text: "hello world",
            language: "en",
            model: "mlx-community/Qwen3-ASR-1.7B-8bit",
            audioDurationS: 5.0,
            processingTimeS: 2.1,
            chunksFed: 10,
            chunkDurationS: 0.5,
            intermediateUpdates: 8
        )
        let output = CLIOutput.formatSuccess(command: "stream-simulate", data: result)
        let parsed = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]

        XCTAssertEqual(parsed?["status"] as? String, "success")
        XCTAssertEqual(parsed?["command"] as? String, "stream-simulate")

        let data = parsed?["data"] as? [String: Any]
        XCTAssertNotNil(data)
        XCTAssertEqual(data?["text"] as? String, "hello world")
        XCTAssertEqual(data?["language"] as? String, "en")
        XCTAssertEqual(data?["model"] as? String, "mlx-community/Qwen3-ASR-1.7B-8bit")
        XCTAssertEqual(data?["audio_duration_s"] as? Double, 5.0)
        XCTAssertEqual(data?["processing_time_s"] as? Double, 2.1)
        XCTAssertEqual(data?["chunks_fed"] as? Int, 10)
        XCTAssertEqual(data?["chunk_duration_s"] as? Double, 0.5)
        XCTAssertEqual(data?["intermediate_updates"] as? Int, 8)
    }
}
