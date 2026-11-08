import Foundation

/// Configuration for `mlx-community/nemotron-3.5-asr-streaming-*` checkpoints
/// (`model_type: nemotron_asr`), as flattened into `config.json` by mlx-audio's converter.
public struct NemotronASRConfig: Decodable, Sendable {
    public struct Preprocessor: Decodable, Sendable {
        public let sampleRate: Int
        public let features: Int
        public let nFft: Int
        public let windowSize: Double
        public let windowStride: Double
        public let window: String
        public let preemph: Double
        public let normalize: String
        public let logZeroGuardValue: Double

        public var winLength: Int { Int((windowSize * Double(sampleRate)).rounded()) }
        public var hopLength: Int { Int((windowStride * Double(sampleRate)).rounded()) }

        enum CodingKeys: String, CodingKey {
            case sampleRate = "sample_rate"
            case features
            case nFft = "n_fft"
            case windowSize = "window_size"
            case windowStride = "window_stride"
            case window, preemph, normalize
            case logZeroGuardValue = "log_zero_guard_value"
        }
    }

    public struct Encoder: Decodable, Sendable {
        public let featIn: Int
        public let nLayers: Int
        public let dModel: Int
        public let nHeads: Int
        public let ffExpansionFactor: Int
        public let subsamplingFactor: Int
        public let subsamplingConvChannels: Int
        public let convKernelSize: Int
        public let causalDownsampling: Bool
        /// `"causal"` in the checkpoint resolves to `[convKernelSize - 1, 0]`.
        public let convContextSize: [Int]
        public let convNormType: String
        public let selfAttentionModel: String
        public let attContextStyle: String
        public let attContextSize: [[Int]]
        public let posEmbMaxLen: Int
        public let useBias: Bool
        public let xscaling: Bool

        enum CodingKeys: String, CodingKey {
            case featIn = "feat_in"
            case nLayers = "n_layers"
            case dModel = "d_model"
            case nHeads = "n_heads"
            case ffExpansionFactor = "ff_expansion_factor"
            case subsamplingFactor = "subsampling_factor"
            case subsamplingConvChannels = "subsampling_conv_channels"
            case convKernelSize = "conv_kernel_size"
            case causalDownsampling = "causal_downsampling"
            case convContextSize = "conv_context_size"
            case convNormType = "conv_norm_type"
            case selfAttentionModel = "self_attention_model"
            case attContextStyle = "att_context_style"
            case attContextSize = "att_context_size"
            case posEmbMaxLen = "pos_emb_max_len"
            case useBias = "use_bias"
            case xscaling
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            featIn = try c.decode(Int.self, forKey: .featIn)
            nLayers = try c.decode(Int.self, forKey: .nLayers)
            dModel = try c.decode(Int.self, forKey: .dModel)
            nHeads = try c.decode(Int.self, forKey: .nHeads)
            ffExpansionFactor = try c.decode(Int.self, forKey: .ffExpansionFactor)
            subsamplingFactor = try c.decode(Int.self, forKey: .subsamplingFactor)
            subsamplingConvChannels = try c.decode(Int.self, forKey: .subsamplingConvChannels)
            convKernelSize = try c.decode(Int.self, forKey: .convKernelSize)
            causalDownsampling = try c.decode(Bool.self, forKey: .causalDownsampling)
            if let context = try? c.decode([Int].self, forKey: .convContextSize), context.count == 2 {
                convContextSize = context
            } else {
                convContextSize = [convKernelSize - 1, 0]
            }
            convNormType = try c.decode(String.self, forKey: .convNormType)
            selfAttentionModel = try c.decode(String.self, forKey: .selfAttentionModel)
            attContextStyle = try c.decode(String.self, forKey: .attContextStyle)
            attContextSize = try c.decode([[Int]].self, forKey: .attContextSize)
            posEmbMaxLen = try c.decode(Int.self, forKey: .posEmbMaxLen)
            useBias = try c.decode(Bool.self, forKey: .useBias)
            xscaling = try c.decode(Bool.self, forKey: .xscaling)
        }
    }

    public struct Prompt: Decodable, Sendable {
        public let numPrompts: Int
        public let promptHidden: Int
        public let promptDictionary: [String: Int]

        enum CodingKeys: String, CodingKey {
            case numPrompts = "num_prompts"
            case promptHidden = "prompt_hidden"
            case promptDictionary = "prompt_dictionary"
        }
    }

    public struct Predictor: Decodable, Sendable {
        public let predHidden: Int
        public let predRnnLayers: Int
        public let vocabSize: Int
        public let blankAsPad: Bool

        enum CodingKeys: String, CodingKey {
            case predHidden = "pred_hidden"
            case predRnnLayers = "pred_rnn_layers"
            case vocabSize = "vocab_size"
            case blankAsPad = "blank_as_pad"
        }
    }

    public struct Joint: Decodable, Sendable {
        public let jointHidden: Int
        public let activation: String
        public let encoderHidden: Int
        public let predHidden: Int
        public let numClasses: Int

        enum CodingKeys: String, CodingKey {
            case jointHidden = "joint_hidden"
            case activation
            case encoderHidden = "encoder_hidden"
            case predHidden = "pred_hidden"
            case numClasses = "num_classes"
        }
    }

    public let modelType: String
    public let preprocessor: Preprocessor
    public let encoder: Encoder
    public let prompt: Prompt
    public let decoder: Predictor
    public let joint: Joint
    public let vocabulary: [String]
    public let defaultLanguage: String
    public let defaultAttContextSize: [Int]
    public let maxSymbols: Int

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case preprocessor, encoder, prompt, decoder, joint, vocabulary
        case defaultLanguage = "default_language"
        case defaultAttContextSize = "default_att_context_size"
        case maxSymbols = "max_symbols"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try c.decode(String.self, forKey: .modelType)
        preprocessor = try c.decode(Preprocessor.self, forKey: .preprocessor)
        encoder = try c.decode(Encoder.self, forKey: .encoder)
        prompt = try c.decode(Prompt.self, forKey: .prompt)
        self.decoder = try c.decode(Predictor.self, forKey: .decoder)
        joint = try c.decode(Joint.self, forKey: .joint)
        vocabulary = try c.decode([String].self, forKey: .vocabulary)
        defaultLanguage = try c.decodeIfPresent(String.self, forKey: .defaultLanguage) ?? "auto"
        defaultAttContextSize = try c.decodeIfPresent([Int].self, forKey: .defaultAttContextSize)
            ?? encoder.attContextSize.first ?? [56, 13]
        maxSymbols = try c.decodeIfPresent(Int.self, forKey: .maxSymbols) ?? 10
    }

    /// Throws when the checkpoint needs a code path this port does not implement
    /// (e.g. Nemotron Unified's buffered, non-causal encoder).
    public func validate() throws {
        func require(_ condition: Bool, _ detail: String) throws {
            if !condition { throw NemotronASRError.unsupportedCheckpoint(detail) }
        }
        try require(modelType == "nemotron_asr", "model_type \(modelType)")
        try require(encoder.attContextStyle == "chunked_limited", "att_context_style \(encoder.attContextStyle)")
        try require(encoder.causalDownsampling, "non-causal subsampling")
        try require(encoder.convContextSize == [encoder.convKernelSize - 1, 0], "non-causal convolution")
        try require(encoder.convNormType == "layer_norm", "conv_norm_type \(encoder.convNormType)")
        try require(encoder.selfAttentionModel == "rel_pos", "self_attention_model \(encoder.selfAttentionModel)")
        try require(preprocessor.normalize == "NA", "feature normalization \(preprocessor.normalize)")
        try require(defaultAttContextSize.count == 2, "att_context_size \(defaultAttContextSize)")
    }
}

public enum NemotronASRError: LocalizedError, Equatable {
    case unsupportedCheckpoint(String)
    case unsupportedLanguage(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedCheckpoint(let detail):
            return "Unsupported Nemotron ASR checkpoint (\(detail)). Only cache-aware streaming Nemotron 3.5 models are supported."
        case .unsupportedLanguage(let language):
            return "Language '\(language)' is not supported by this Nemotron model."
        }
    }
}
