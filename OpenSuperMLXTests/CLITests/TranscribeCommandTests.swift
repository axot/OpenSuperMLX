// TranscribeCommandTests.swift
// OpenSuperMLXTests

import XCTest

import ArgumentParser
@testable import OpenSuperMLX

@MainActor
final class TranscribeCommandTests: XCTestCase {

    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "TranscribeCommandTests")!
        testDefaults.removePersistentDomain(forName: "TranscribeCommandTests")
        AppPreferences.store = testDefaults
    }

    override func tearDown() {
        AppPreferences.store = .standard
        testDefaults.removePersistentDomain(forName: "TranscribeCommandTests")
        testDefaults = nil
        super.tearDown()
    }

    // MARK: - File Validation

    func testTranscribeNonExistentFile() async throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(["transcribe", "/nonexistent.wav", "--json"]) as! TranscribeCommand

        let service = TranscriptionService(engine: nil)
        let result = await command.executeTranscription(service: service)

        guard case .failure(let error) = result else {
            XCTFail("Expected failure for non-existent file"); return
        }
        XCTAssertEqual(error, .audioFileNotFound)
    }

    // MARK: - JSON Output Schema

    func testTranscribeJSONOutputSchema() throws {
        let result = TranscribeResult(
            text: "hello world",
            language: "en",
            model: "mlx-community/Qwen3-ASR-1.7B-8bit",
            audioDurationS: 3.5,
            processingTimeS: 1.2,
            correctionsApplied: ["itn", "autocorrect"]
        )
        let output = CLIOutput.formatSuccess(command: "transcribe", data: result)
        let parsed = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]

        XCTAssertEqual(parsed?["status"] as? String, "success")
        XCTAssertEqual(parsed?["command"] as? String, "transcribe")

        let data = parsed?["data"] as? [String: Any]
        XCTAssertNotNil(data)
        XCTAssertEqual(data?["text"] as? String, "hello world")
        XCTAssertEqual(data?["language"] as? String, "en")
        XCTAssertEqual(data?["model"] as? String, "mlx-community/Qwen3-ASR-1.7B-8bit")
        XCTAssertEqual(data?["audio_duration_s"] as? Double, 3.5)
        XCTAssertEqual(data?["processing_time_s"] as? Double, 1.2)
        let corrections = data?["corrections_applied"] as? [String]
        XCTAssertEqual(corrections, ["itn", "autocorrect"])
    }

    // MARK: - Argument Parsing

    func testTranscribeNoCorrectionFlag() throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(
            ["transcribe", "file.wav", "--no-correction"]
        ) as! TranscribeCommand
        XCTAssertTrue(command.noCorrection)
    }

    func testTranscribeLanguageOption() throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(
            ["transcribe", "file.wav", "--language", "zh"]
        ) as! TranscribeCommand
        XCTAssertEqual(command.language, "zh")
    }

    func testTranscribeModelOption() throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(
            ["transcribe", "file.wav", "--model", "mlx-community/Qwen3-ASR-1.7B-8bit"]
        ) as! TranscribeCommand
        XCTAssertEqual(command.model, "mlx-community/Qwen3-ASR-1.7B-8bit")
    }

    // MARK: - Successful Transcription

    func testTranscribeWithMockEngine() async throws {
        let mockEngine = MockTranscriptionEngine()
        mockEngine.transcribeResult = "test transcription output"
        let service = TranscriptionService(engine: mockEngine)

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_audio_\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: tempFile.path, contents: Data([0]), attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        var command = try OpenSuperMLXCLI.parseAsRoot(
            ["transcribe", tempFile.path, "--json", "--no-correction"]
        ) as! TranscribeCommand

        let result = await command.executeTranscription(service: service)

        guard case .success(let transcribeResult) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertEqual(transcribeResult.text, "test transcription output")
        XCTAssertEqual(mockEngine.transcribeCallCount, 1)
    }

    // MARK: - Corrections List

    func testCorrectionsList() {
        let withLLM = TranscribeCommand.buildCorrectionsList(
            noCorrection: false, llmEnabled: true
        )
        XCTAssertEqual(withLLM, ["itn", "autocorrect", "llm"])

        let withoutLLM = TranscribeCommand.buildCorrectionsList(
            noCorrection: false, llmEnabled: false
        )
        XCTAssertEqual(withoutLLM, ["itn", "autocorrect"])

        let noCorrection = TranscribeCommand.buildCorrectionsList(
            noCorrection: true, llmEnabled: true
        )
        XCTAssertEqual(noCorrection, ["itn", "autocorrect"])
    }
}
