// CLIOutputTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class CLIOutputTests: XCTestCase {

    // MARK: - JSON Success Output

    func testJSONSuccessOutputFormat() throws {
        let data = ["text": "hello world", "language": "en"]
        let output = CLIOutput.formatSuccess(command: "transcribe", data: data)
        let parsed = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]

        XCTAssertEqual(parsed?["status"] as? String, "success")
        XCTAssertEqual(parsed?["command"] as? String, "transcribe")
        let resultData = parsed?["data"] as? [String: String]
        XCTAssertEqual(resultData?["text"], "hello world")
        XCTAssertEqual(resultData?["language"], "en")
    }

    // MARK: - JSON Error Output

    func testJSONErrorOutputFormat() throws {
        let output = CLIOutput.formatError(command: "transcribe", error: .audioFileNotFound)
        let parsed = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]

        XCTAssertEqual(parsed?["status"] as? String, "error")
        XCTAssertEqual(parsed?["command"] as? String, "transcribe")
        let errorDetail = parsed?["error"] as? [String: String]
        XCTAssertEqual(errorDetail?["code"], "audio_file_not_found")
        XCTAssertEqual(errorDetail?["message"], "Audio file not found")
    }

    // MARK: - Error Descriptions

    func testAllErrorCodesHaveDescriptions() {
        let allCases: [CLIError] = [
            .modelNotFound, .modelNotCached, .modelLoadFailed,
            .audioFileNotFound, .audioFormatUnsupported, .transcriptionFailed,
            .streamTimeout, .llmCorrectionFailed, .databaseError,
            .audioFileMissing, .invalidConfigKey, .invalidConfigValue,
        ]
        for error in allCases {
            XCTAssertFalse(error.description.isEmpty, "\(error.rawValue) has empty description")
        }
    }

    // MARK: - Human-Readable Output

    func testHumanReadableOutput() {
        let data = ["text": "hello world"]
        let output = CLIOutput.formatSuccess(command: "transcribe", data: data, json: false)

        XCTAssertFalse(output.contains("\"status\""))
        XCTAssertTrue(output.contains("hello world"))
    }

    // MARK: - Error Exit Codes

    func testErrorExitCode() {
        let allCases: [CLIError] = [
            .modelNotFound, .modelNotCached, .modelLoadFailed,
            .audioFileNotFound, .audioFormatUnsupported, .transcriptionFailed,
            .streamTimeout, .llmCorrectionFailed, .databaseError,
            .audioFileMissing, .invalidConfigKey, .invalidConfigValue,
        ]
        for error in allCases {
            XCTAssertEqual(error.exitCode, 1, "\(error.rawValue) should have exit code 1")
        }
    }

    // MARK: - Error Code Raw Values

    func testErrorCodeRawValues() {
        XCTAssertEqual(CLIError.modelNotFound.rawValue, "model_not_found")
        XCTAssertEqual(CLIError.modelNotCached.rawValue, "model_not_cached")
        XCTAssertEqual(CLIError.modelLoadFailed.rawValue, "model_load_failed")
        XCTAssertEqual(CLIError.audioFileNotFound.rawValue, "audio_file_not_found")
        XCTAssertEqual(CLIError.audioFormatUnsupported.rawValue, "audio_format_unsupported")
        XCTAssertEqual(CLIError.transcriptionFailed.rawValue, "transcription_failed")
        XCTAssertEqual(CLIError.streamTimeout.rawValue, "stream_timeout")
        XCTAssertEqual(CLIError.llmCorrectionFailed.rawValue, "llm_correction_failed")
        XCTAssertEqual(CLIError.databaseError.rawValue, "database_error")
        XCTAssertEqual(CLIError.audioFileMissing.rawValue, "audio_file_missing")
        XCTAssertEqual(CLIError.invalidConfigKey.rawValue, "invalid_config_key")
        XCTAssertEqual(CLIError.invalidConfigValue.rawValue, "invalid_config_value")
    }
}
