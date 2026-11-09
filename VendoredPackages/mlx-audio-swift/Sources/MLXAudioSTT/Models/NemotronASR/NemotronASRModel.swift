import Foundation
import MLX
import MLXLMCommon
import MLXNN

// MARK: - RNN-T Joint

final class NemotronJointNetwork: Module {
    private let activation: String

    @ModuleInfo(key: "enc") var enc: Linear
    @ModuleInfo(key: "pred") var pred: Linear
    @ModuleInfo(key: "joint_net") var output: Linear

    init(config: NemotronASRConfig.Joint) {
        activation = config.activation.lowercased()
        _enc.wrappedValue = Linear(config.encoderHidden, config.jointHidden)
        _pred.wrappedValue = Linear(config.predHidden, config.jointHidden)
        _output.wrappedValue = Linear(config.jointHidden, config.numClasses + 1)
    }

    func logits(encoderProjection: MLXArray, predictionProjection: MLXArray) -> MLXArray {
        let x = encoderProjection + predictionProjection
        switch activation {
        case "sigmoid": return output(sigmoid(x))
        case "tanh": return output(tanh(x))
        default: return output(relu(x))
        }
    }
}

// MARK: - Model

/// NVIDIA Nemotron 3.5 ASR: a cache-aware streaming FastConformer-RNNT with language-ID prompt
/// conditioning. Port of mlx-audio's `nemotron_asr` model (cache-aware path only).
public final class NemotronASRModel: Module {
    public let config: NemotronASRConfig

    @ModuleInfo(key: "encoder") var encoder: NemotronASREncoder
    @ModuleInfo(key: "prompt_kernel") var promptKernel: [Linear]
    @ModuleInfo(key: "decoder") var decoder: ParakeetPredictNetwork
    @ModuleInfo(key: "joint") var joint: NemotronJointNetwork

    private let audio: NemotronASRAudio
    private var blankToken: Int { config.decoder.vocabSize }

    /// Mel frames computed per STFT pass, bounding front-end memory on long files.
    private static let melChunkFrames = 3000

    public init(config: NemotronASRConfig) throws {
        try config.validate()
        self.config = config
        audio = NemotronASRAudio(config: config.preprocessor)
        _encoder.wrappedValue = NemotronASREncoder(config: config.encoder)
        _promptKernel.wrappedValue = [
            Linear(config.encoder.dModel + config.prompt.numPrompts, config.prompt.promptHidden),
            Linear(config.prompt.promptHidden, config.encoder.dModel),
        ]
        _decoder.wrappedValue = ParakeetPredictNetwork(
            args: ParakeetPredictConfig(
                blankAsPad: config.decoder.blankAsPad,
                vocabSize: config.decoder.vocabSize,
                prednet: ParakeetPredictNetworkConfig(
                    predHidden: config.decoder.predHidden,
                    predRnnLayers: config.decoder.predRnnLayers,
                    rnnHiddenSize: nil
                )
            )
        )
        _joint.wrappedValue = NemotronJointNetwork(config: config.joint)
    }

    // MARK: - Language Prompt

    /// Resolves a language to its prompt index: an exact `prompt_dictionary` key (`en`, `de-DE`,
    /// `auto`), or a bare code whose locale keys all share one prompt (`ja` → `ja-JP`).
    /// `nil` selects the model's default language.
    public func promptIndex(for language: String?) -> Int? {
        let dictionary = config.prompt.promptDictionary
        let key = language ?? config.defaultLanguage
        if let index = dictionary[key] {
            return index
        }
        let prefix = key.lowercased() + "-"
        let matches = Set(dictionary.filter { $0.key.lowercased().hasPrefix(prefix) }.values)
        return matches.count == 1 ? matches.first : nil
    }

    private func applyPrompt(_ encoded: MLXArray, promptIndex: Int) -> MLXArray {
        let (b, t) = (encoded.shape[0], encoded.shape[1])
        var oneHot = [Float](repeating: 0, count: config.prompt.numPrompts)
        oneHot[promptIndex] = 1
        let prompt = MLX.broadcast(
            MLXArray(oneHot).asType(encoded.dtype).reshaped([1, 1, -1]),
            to: [b, t, config.prompt.numPrompts]
        )
        let x = MLX.concatenated([encoded, prompt], axis: -1)
        return promptKernel[1](relu(promptKernel[0](x)))
    }

    // MARK: - Transcription

    /// Transcribes 16 kHz mono audio. `language` is a prompt key or bare language code; `nil`
    /// uses the checkpoint default (`auto`, which detects the language).
    public func transcribe(audio waveform: MLXArray, language: String? = nil) throws -> String {
        guard let promptIndex = promptIndex(for: language) else {
            throw NemotronASRError.unsupportedLanguage(language ?? config.defaultLanguage)
        }
        let samples = waveform.ndim > 1 ? waveform.mean(axis: -1) : waveform
        guard samples.shape[0] >= config.preprocessor.nFft else { return "" }

        let preemphasized = audio.preemphasize(samples.asType(.float32))
        let totalFrames = audio.frameCount(samples: samples.shape[0])
        let state = NemotronEncoderStreamingState(encoder: encoder, attContextSize: config.defaultAttContextSize)
        var decoderState = GreedyDecoderState()
        var tokens: [Int] = []

        var frameStart = 0
        while frameStart < totalFrames {
            let frameEnd = min(frameStart + Self.melChunkFrames, totalFrames)
            let mel = audio.logMel(preemphasized: preemphasized, frameStart: frameStart, frameEnd: frameEnd)
            for encoded in state.push(mel, final: frameEnd == totalFrames) {
                let prompted = applyPrompt(encoded, promptIndex: promptIndex)
                tokens += greedyDecode(prompted, state: &decoderState)
            }
            frameStart = frameEnd
        }
        return NemotronASRTokenizer.decode(tokens, vocabulary: config.vocabulary)
    }

    // MARK: - Greedy RNN-T Decoding

    struct GreedyDecoderState {
        var lastToken: Int?
        var lstmState: ParakeetLSTMState?
        /// Predictor output for `lastToken`; blanks advance only the audio clock, so it is
        /// reused until a token is emitted.
        var predictionProjection: MLXArray?
        var nextLSTMState: ParakeetLSTMState?
    }

    private func greedyDecode(_ features: MLXArray, state: inout GreedyDecoderState) -> [Int] {
        let encoderProjection = joint.enc(features)
        var emitted: [Int] = []
        for t in 0..<features.shape[1] {
            let frame = encoderProjection[0..., t..<(t + 1), 0...]
            var symbols = 0
            while symbols < config.maxSymbols {
                if state.predictionProjection == nil {
                    let token = state.lastToken.map { MLXArray([Int32($0)]).reshaped([1, 1]) }
                    let (prediction, next) = decoder(token, state: state.lstmState)
                    state.predictionProjection = joint.pred(prediction.asType(features.dtype))
                    state.nextLSTMState = (next.hidden?.asType(features.dtype), next.cell?.asType(features.dtype))
                }
                let logits = joint.logits(encoderProjection: frame, predictionProjection: state.predictionProjection!)
                let token = logits.argMax(axis: -1).item(Int.self)
                if token == blankToken { break }

                state.lastToken = token
                state.lstmState = state.nextLSTMState
                state.predictionProjection = nil
                if !NemotronASRTokenizer.isSpecial(token, vocabulary: config.vocabulary) {
                    emitted.append(token)
                }
                symbols += 1
            }
        }
        return emitted
    }
}

// MARK: - Tokenizer

enum NemotronASRTokenizer {
    private static let specialPieces: Set<String> = ["<unk>", "<pad>", "<s>", "</s>"]
    private static let languageTag = try! NSRegularExpression(pattern: "^<[a-z]{2,3}-[A-Za-z]{2,4}>$")

    static func isLanguageTag(_ piece: String) -> Bool {
        languageTag.firstMatch(in: piece, range: NSRange(piece.startIndex..., in: piece)) != nil
    }

    static func isSpecial(_ token: Int, vocabulary: [String]) -> Bool {
        guard vocabulary.indices.contains(token) else { return false }
        let piece = vocabulary[token]
        return specialPieces.contains(piece) || isLanguageTag(piece)
    }

    /// Joins SentencePiece pieces (`▁` marks a space). A standalone `▁` piece after sentence
    /// punctuation would otherwise produce a double space, so runs of spaces are collapsed.
    static func decode(_ tokens: [Int], vocabulary: [String]) -> String {
        tokens
            .filter { vocabulary.indices.contains($0) && !isSpecial($0, vocabulary: vocabulary) }
            .map { vocabulary[$0].replacingOccurrences(of: "\u{2581}", with: " ") }
            .joined()
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Loading

public extension NemotronASRModel {
    static func fromDirectory(_ directory: URL) throws -> NemotronASRModel {
        let configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let config = try JSONDecoder().decode(NemotronASRConfig.self, from: configData)
        let model = try NemotronASRModel(config: config)

        var weights: [String: MLXArray] = [:]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "safetensors" {
            weights.merge(try MLX.loadArrays(url: file)) { _, new in new }
        }
        let sanitized = sanitize(weights)

        if let quantization = try? JSONDecoder().decode(BaseConfiguration.self, from: configData).perLayerQuantization {
            quantize(model: model) { path, _ in
                sanitized["\(path).scales"] != nil ? quantization.quantization(layer: path)?.asTuple : nil
            }
        }

        try model.update(parameters: ModuleParameters.unflattened(sanitized), verify: .all)
        eval(model)
        return model
    }

    /// Maps mlx-audio's Python module paths onto this port's module tree.
    internal static func sanitize(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        let preEncode = try! NSRegularExpression(pattern: #"^encoder\.pre_encode\.conv\.(\d+)\."#)
        var result: [String: MLXArray] = [:]
        for (key, value) in weights {
            var newKey = key
                .replacingOccurrences(of: ".pos_bias_u", with: ".posBiasU")
                .replacingOccurrences(of: ".pos_bias_v", with: ".posBiasV")
                .replacingOccurrences(of: "joint.joint_net.2.", with: "joint.joint_net.")
                .replacingOccurrences(of: "prompt_kernel.2.", with: "prompt_kernel.1.")
            let range = NSRange(newKey.startIndex..., in: newKey)
            if let match = preEncode.firstMatch(in: newKey, range: range),
               let indexRange = Range(match.range(at: 1), in: newKey),
               let index = Int(newKey[indexRange]) {
                // Python list [conv, ReLU, (dw, pw, ReLU) × n]: 0 → conv_in, 2+3i → dw i, 3+3i → pw i.
                let module: String
                switch index {
                case 0: module = "conv_in"
                case let i where (i - 2) % 3 == 0: module = "depthwise.\((i - 2) / 3)"
                default: module = "pointwise.\((index - 3) / 3)"
                }
                newKey = newKey.replacingCharacters(
                    in: Range(match.range, in: newKey)!,
                    with: "encoder.pre_encode.\(module)."
                )
            }
            result[newKey] = value
        }
        return result
    }
}
