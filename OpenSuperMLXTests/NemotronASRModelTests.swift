// NemotronASRModelTests.swift
// OpenSuperMLXTests

import XCTest

import MLX
@testable import MLXAudioSTT

final class NemotronASRModelTests: XCTestCase {

    private var model: NemotronASRModel!

    override func setUpWithError() throws {
        MLXRandom.seed(3)
        model = try NemotronASRModel(config: try NemotronASRFixtures.config())
    }

    // MARK: - Language Prompt

    func testPromptIndexResolvesExactKeysAndUnambiguousBareCodes() {
        XCTAssertEqual(model.promptIndex(for: nil), 7)
        XCTAssertEqual(model.promptIndex(for: "en"), 0)
        XCTAssertEqual(model.promptIndex(for: "de"), 1)
        XCTAssertEqual(model.promptIndex(for: "ja"), 2)
        XCTAssertEqual(model.promptIndex(for: "zh-CN"), 3)
    }

    func testPromptIndexRejectsAmbiguousAndUnknownLanguages() {
        XCTAssertNil(model.promptIndex(for: "zh"))
        XCTAssertNil(model.promptIndex(for: "ca"))
    }

    // MARK: - Tokenizer

    func testDecodeDropsLanguageTagsAndCollapsesSpaces() {
        let text = NemotronASRTokenizer.decode([1, 3, 4, 5, 2, 3, 0], vocabulary: model.config.vocabulary)

        XCTAssertEqual(text, "hello world. hello")
    }

    // MARK: - Weight Keys

    func testSanitizeMapsPythonModulePaths() {
        let value = MLXArray.zeros([1])
        let keys = Set(NemotronASRModel.sanitize([
            "encoder.pre_encode.conv.0.weight": value,
            "encoder.pre_encode.conv.2.weight": value,
            "encoder.pre_encode.conv.6.bias": value,
            "encoder.layers.3.self_attn.pos_bias_u": value,
            "joint.joint_net.2.weight": value,
            "prompt_kernel.2.bias": value,
        ]).keys)

        XCTAssertEqual(keys, [
            "encoder.pre_encode.conv_in.weight",
            "encoder.pre_encode.depthwise.0.weight",
            "encoder.pre_encode.pointwise.1.bias",
            "encoder.layers.3.self_attn.posBiasU",
            "joint.joint_net.weight",
            "prompt_kernel.1.bias",
        ])
    }

    func testSanitizedKeysCoverEveryModelParameter() {
        let parameterKeys = Set(model.parameters().flattened().map(\.0))
        let pythonKeys = parameterKeys.map { key in
            key.replacingOccurrences(of: "posBiasU", with: "pos_bias_u")
                .replacingOccurrences(of: "posBiasV", with: "pos_bias_v")
                .replacingOccurrences(of: "joint.joint_net.", with: "joint.joint_net.2.")
                .replacingOccurrences(of: "prompt_kernel.1.", with: "prompt_kernel.2.")
                .replacingOccurrences(of: "pre_encode.conv_in.", with: "pre_encode.conv.0.")
                .replacingOccurrences(of: "pre_encode.depthwise.0.", with: "pre_encode.conv.2.")
                .replacingOccurrences(of: "pre_encode.pointwise.0.", with: "pre_encode.conv.3.")
                .replacingOccurrences(of: "pre_encode.depthwise.1.", with: "pre_encode.conv.5.")
                .replacingOccurrences(of: "pre_encode.pointwise.1.", with: "pre_encode.conv.6.")
        }
        let weights = Dictionary(uniqueKeysWithValues: pythonKeys.map { ($0, MLXArray.zeros([1])) })

        XCTAssertEqual(Set(NemotronASRModel.sanitize(weights).keys), parameterKeys)
    }

    // MARK: - Transcription

    func testTranscribeRunsEndToEndAndHandlesTooShortAudio() throws {
        MLXRandom.seed(5)

        XCTAssertNoThrow(try model.transcribe(audio: MLXRandom.normal([24000]) * 0.1, language: "en"))
        XCTAssertEqual(try model.transcribe(audio: MLXArray.zeros([100])), "")
    }

    func testTranscribeRejectsUnsupportedLanguages() {
        XCTAssertThrowsError(try model.transcribe(audio: MLXArray.zeros([16000]), language: "ca")) { error in
            XCTAssertEqual(error as? NemotronASRError, .unsupportedLanguage("ca"))
        }
    }
}
