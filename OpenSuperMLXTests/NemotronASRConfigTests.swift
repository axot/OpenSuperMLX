// NemotronASRConfigTests.swift
// OpenSuperMLXTests

import XCTest

@testable import MLXAudioSTT

/// A tiny randomly initialized Nemotron 3.5 layout, small enough for unit tests.
enum NemotronASRFixtures {
    static let configJSON = """
    {
      "model_type": "nemotron_asr",
      "preprocessor": {"sample_rate": 16000, "features": 16, "n_fft": 512, "window_size": 0.025,
        "window_stride": 0.01, "window": "hann", "preemph": 0.97, "normalize": "NA",
        "log_zero_guard_value": 5.960464477539063e-08},
      "encoder": {"feat_in": 16, "n_layers": 2, "d_model": 32, "n_heads": 4, "ff_expansion_factor": 2,
        "subsampling_factor": 8, "subsampling_conv_channels": 8, "conv_kernel_size": 9,
        "causal_downsampling": true, "conv_context_size": "causal", "conv_norm_type": "layer_norm",
        "self_attention_model": "rel_pos", "att_context_style": "chunked_limited",
        "att_context_size": [[56, 13]], "pos_emb_max_len": 5000, "use_bias": false, "xscaling": false},
      "prompt": {"num_prompts": 8, "prompt_hidden": 16, "prompt_dictionary": {"en-US": 0, "en": 0,
        "de-DE": 1, "ja-JP": 2, "ja-JA": 2, "zh-CN": 3, "zh-TW": 4, "auto": 7}},
      "decoder": {"pred_hidden": 16, "pred_rnn_layers": 1, "vocab_size": 6, "blank_as_pad": true},
      "joint": {"joint_hidden": 16, "activation": "relu", "encoder_hidden": 32, "pred_hidden": 16, "num_classes": 6},
      "vocabulary": ["<unk>", "<en-US>", "\\u2581", "\\u2581hello", "\\u2581world", "."],
      "default_language": "auto",
      "default_att_context_size": [56, 13],
      "max_symbols": 10
    }
    """

    static func config(replacing target: String = "", with replacement: String = "") throws -> NemotronASRConfig {
        let json = target.isEmpty ? configJSON : configJSON.replacingOccurrences(of: target, with: replacement)
        return try JSONDecoder().decode(NemotronASRConfig.self, from: Data(json.utf8))
    }
}

final class NemotronASRConfigTests: XCTestCase {

    // MARK: - Decoding

    func testDecodesDerivedFrontendSizesAndCausalConvContext() throws {
        let config = try NemotronASRFixtures.config()

        XCTAssertEqual(config.preprocessor.winLength, 400)
        XCTAssertEqual(config.preprocessor.hopLength, 160)
        XCTAssertEqual(config.encoder.convContextSize, [8, 0])
        XCTAssertEqual(config.defaultAttContextSize, [56, 13])
        XCTAssertNoThrow(try config.validate())
    }

    func testMissingOptionalFieldsFallBackToDefaults() throws {
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(NemotronASRFixtures.configJSON.utf8)) as? [String: Any]
        )
        for key in ["default_language", "default_att_context_size", "max_symbols"] {
            json.removeValue(forKey: key)
        }
        var encoder = try XCTUnwrap(json["encoder"] as? [String: Any])
        encoder["att_context_size"] = [[70, 6], [70, 0]]
        json["encoder"] = encoder

        let config = try JSONDecoder().decode(
            NemotronASRConfig.self, from: JSONSerialization.data(withJSONObject: json)
        )

        XCTAssertEqual(config.defaultLanguage, "auto")
        XCTAssertEqual(config.defaultAttContextSize, [70, 6])
        XCTAssertEqual(config.maxSymbols, 10)
    }

    // MARK: - Validation

    func testRejectsBufferedUnifiedCheckpoints() throws {
        let config = try NemotronASRFixtures.config(
            replacing: "\"att_context_style\": \"chunked_limited\"",
            with: "\"att_context_style\": \"chunked_limited_with_rc\""
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard case NemotronASRError.unsupportedCheckpoint = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testRejectsNonCausalConvolutionAndNormalizedFeatures() throws {
        let symmetric = try NemotronASRFixtures.config(
            replacing: "\"conv_context_size\": \"causal\"", with: "\"conv_context_size\": [4, 4]"
        )
        let normalized = try NemotronASRFixtures.config(
            replacing: "\"normalize\": \"NA\"", with: "\"normalize\": \"per_feature\""
        )

        XCTAssertThrowsError(try symmetric.validate())
        XCTAssertThrowsError(try normalized.validate())
    }
}
