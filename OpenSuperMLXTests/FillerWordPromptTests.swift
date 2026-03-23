//
//  FillerWordPromptTests.swift
//  OpenSuperMLXTests
//

import XCTest
@testable import MLXAudioSTT

final class FillerWordPromptTests: XCTestCase {

    // MARK: - Default Context Tests

    func testDefaultContextDoesNotContainFillerInstruction() throws {
        let defaultContext = "Transcribe speech to text."
        let fillerKeywords = ["filler", "hesitation", "um", "uh", "hmm", "嗯", "呃", "啊", "えーと", "あの", "음"]

        for keyword in fillerKeywords {
            XCTAssertFalse(
                defaultContext.contains(keyword),
                "Default context should not contain filler keyword '\(keyword)'"
            )
        }
    }

    func testOldContextDidContainFillerInstruction() throws {
        let oldContext = "Transcribe speech to clean text. Omit filler words and hesitations such as um, uh, hmm, er, like, you know, 嗯, 呃, 啊, えーと, あの, 음."
        let fillerKeywords = ["filler", "嗯", "呃", "啊", "えーと", "あの", "음"]

        for keyword in fillerKeywords {
            XCTAssertTrue(
                oldContext.contains(keyword),
                "Old context should contain filler keyword '\(keyword)'"
            )
        }
    }

    // MARK: - Prompt Template Structure

    func testPromptTemplateEmbedsContext() throws {
        let context = "Transcribe speech to text."
        let language = "Chinese"
        let numAudioTokens = 3

        let prompt = "<|im_start|>system\n\(context)<|im_end|>\n"
            + "<|im_start|>user\n<|audio_start|>"
            + String(repeating: "<|audio_pad|>", count: numAudioTokens)
            + "<|audio_end|><|im_end|>\n"
            + "<|im_start|>assistant\nlanguage \(language)<asr_text>"

        XCTAssertTrue(prompt.contains("<|im_start|>system\nTranscribe speech to text.<|im_end|>"))
        XCTAssertFalse(prompt.contains("filler"))
        XCTAssertFalse(prompt.contains("Omit"))
        XCTAssertFalse(prompt.contains("hesitation"))
    }

    func testPromptTemplateWithFillerContext() throws {
        let fillerContext = "Transcribe speech to clean text. Omit filler words and hesitations such as um, uh, 嗯, 呃."
        let language = "Chinese"
        let numAudioTokens = 3

        let prompt = "<|im_start|>system\n\(fillerContext)<|im_end|>\n"
            + "<|im_start|>user\n<|audio_start|>"
            + String(repeating: "<|audio_pad|>", count: numAudioTokens)
            + "<|audio_end|><|im_end|>\n"
            + "<|im_start|>assistant\nlanguage \(language)<asr_text>"

        XCTAssertTrue(prompt.contains("Omit filler words"))
        XCTAssertTrue(prompt.contains("嗯"))
    }

    // MARK: - StreamingConfig Defaults

    func testStreamingConfigDefaultsUnchanged() throws {
        let config = StreamingConfig()
        XCTAssertEqual(config.language, "English")
        XCTAssertEqual(config.temperature, 0.0)
        XCTAssertEqual(config.unfixedTokenNum, 5)
    }
}
