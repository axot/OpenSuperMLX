import Foundation
import MLX
import MLXNN

// MARK: - Subsampling

/// Causal `dw_striding` subsampling. Each stride-2 conv is padded `k - 1` on the left and
/// `stride - 1` on the right, on both the time and frequency axes (NeMo `CausalConv2D`).
final class NemotronCausalSubsampling: Module {
    private let kernelSize = 3
    private let stride = 2
    private let padLeft: Int
    private let padRight: Int

    @ModuleInfo(key: "conv_in") var convIn: Conv2d
    @ModuleInfo(key: "depthwise") var depthwise: [Conv2d]
    @ModuleInfo(key: "pointwise") var pointwise: [Conv2d]
    @ModuleInfo(key: "out") var out: Linear

    init(config: NemotronASRConfig.Encoder) {
        let channels = config.subsamplingConvChannels
        let samplingNum = Int(log2(Double(config.subsamplingFactor)))
        padLeft = kernelSize - 1
        padRight = stride - 1

        var freq = config.featIn
        for _ in 0..<samplingNum {
            freq = (freq + padLeft + padRight - kernelSize) / stride + 1
        }

        _convIn.wrappedValue = Conv2d(inputChannels: 1, outputChannels: channels, kernelSize: 3, stride: 2)
        _depthwise.wrappedValue = (1..<samplingNum).map { _ in
            Conv2d(inputChannels: channels, outputChannels: channels, kernelSize: 3, stride: 2, groups: channels)
        }
        _pointwise.wrappedValue = (1..<samplingNum).map { _ in
            Conv2d(inputChannels: channels, outputChannels: channels, kernelSize: 1)
        }
        _out.wrappedValue = Linear(channels * freq, config.dModel)
    }

    /// `(B, T, F)` mel → `(B, T', dModel)`.
    func callAsFunction(_ mel: MLXArray) -> MLXArray {
        var x = relu(convIn(causalPad(mel.expandedDimensions(axis: -1))))
        for (dw, pw) in zip(depthwise, pointwise) {
            x = relu(pw(dw(causalPad(x))))
        }
        let (b, t, f, c) = (x.shape[0], x.shape[1], x.shape[2], x.shape[3])
        return out(x.transposed(0, 1, 3, 2).reshaped([b, t, c * f]))
    }

    private func causalPad(_ x: MLXArray) -> MLXArray {
        MLX.padded(x, widths: [.init(0), .init((padLeft, padRight)), .init((padLeft, padRight)), .init(0)])
    }
}

// MARK: - Convolution Module

/// Conformer convolution with a causal depthwise conv. NeMo names the LayerNorm `batch_norm`;
/// the key is kept so checkpoint weights line up.
final class NemotronConvolution: Module {
    let contextFrames: Int

    @ModuleInfo(key: "pointwise_conv1") var pointwiseConv1: Conv1d
    @ModuleInfo(key: "depthwise_conv") var depthwiseConv: Conv1d
    @ModuleInfo(key: "batch_norm") var norm: LayerNorm
    @ModuleInfo(key: "pointwise_conv2") var pointwiseConv2: Conv1d

    init(config: NemotronASRConfig.Encoder) {
        let d = config.dModel
        contextFrames = config.convKernelSize - 1
        _pointwiseConv1.wrappedValue = Conv1d(inputChannels: d, outputChannels: d * 2, kernelSize: 1, bias: config.useBias)
        _depthwiseConv.wrappedValue = Conv1d(
            inputChannels: d, outputChannels: d, kernelSize: config.convKernelSize, groups: d, bias: config.useBias
        )
        _norm.wrappedValue = LayerNorm(dimensions: d)
        _pointwiseConv2.wrappedValue = Conv1d(inputChannels: d, outputChannels: d, kernelSize: 1, bias: config.useBias)
    }

    /// Runs the conv on `x` (B, c, d) with `cache` holding the previous `contextFrames` GLU
    /// outputs (zeros at stream start). Returns the output and the next cache.
    func step(_ x: MLXArray, cache: MLXArray?) -> (MLXArray, MLXArray) {
        let projected = pointwiseConv1(x)
        let halves = projected.split(parts: 2, axis: -1)
        let gated = halves[0] * sigmoid(halves[1])
        let history = cache ?? MLXArray.zeros([gated.shape[0], contextFrames, gated.shape[2]], dtype: gated.dtype)
        let input = MLX.concatenated([history, gated], axis: 1)
        let nextCache = input[0..., (input.shape[1] - contextFrames)..., 0...]
        let y = pointwiseConv2(silu(norm(depthwiseConv(input))))
        return (y, nextCache)
    }
}

// MARK: - Conformer Block

final class NemotronConformerBlock: Module {
    @ModuleInfo(key: "norm_feed_forward1") var normFeedForward1: LayerNorm
    @ModuleInfo(key: "feed_forward1") var feedForward1: ParakeetFeedForward
    @ModuleInfo(key: "norm_self_att") var normSelfAtt: LayerNorm
    @ModuleInfo(key: "self_attn") var selfAttn: ParakeetRelPositionMultiHeadAttention
    @ModuleInfo(key: "norm_conv") var normConv: LayerNorm
    @ModuleInfo(key: "conv") var conv: NemotronConvolution
    @ModuleInfo(key: "norm_feed_forward2") var normFeedForward2: LayerNorm
    @ModuleInfo(key: "feed_forward2") var feedForward2: ParakeetFeedForward
    @ModuleInfo(key: "norm_out") var normOut: LayerNorm

    init(config: NemotronASRConfig.Encoder) {
        let d = config.dModel
        let ff = d * config.ffExpansionFactor
        _normFeedForward1.wrappedValue = LayerNorm(dimensions: d)
        _feedForward1.wrappedValue = ParakeetFeedForward(dModel: d, dFF: ff, useBias: config.useBias)
        _normSelfAtt.wrappedValue = LayerNorm(dimensions: d)
        _selfAttn.wrappedValue = ParakeetRelPositionMultiHeadAttention(nHead: config.nHeads, nFeat: d, bias: config.useBias)
        _normConv.wrappedValue = LayerNorm(dimensions: d)
        _conv.wrappedValue = NemotronConvolution(config: config)
        _normFeedForward2.wrappedValue = LayerNorm(dimensions: d)
        _feedForward2.wrappedValue = ParakeetFeedForward(dModel: d, dFF: ff, useBias: config.useBias)
        _normOut.wrappedValue = LayerNorm(dimensions: d)
    }

    /// Cache-aware step: the chunk's queries attend to `[attentionCache ++ chunk]`. With the
    /// cache sized to the left context, no mask is needed.
    func step(
        _ x: MLXArray,
        attentionCache: MLXArray?,
        convCache: MLXArray?,
        leftContext: Int,
        posEnc: ParakeetRelPositionalEncoding
    ) -> (MLXArray, MLXArray, MLXArray) {
        var residual = x + 0.5 * feedForward1(normFeedForward1(x))

        let normed = normSelfAtt(residual)
        let keys = attentionCache.map { MLX.concatenated([$0, normed], axis: 1) } ?? normed
        let posEmb = posEnc.embedding(length: keys.shape[1], dtype: x.dtype)
        residual = residual + selfAttn(normed, keys, keys, posEmb: posEmb)
        let kept = min(leftContext, keys.shape[1])
        let nextAttentionCache = keys[0..., (keys.shape[1] - kept)..., 0...]

        let (convOut, nextConvCache) = conv.step(normConv(residual), cache: convCache)
        residual = residual + convOut

        residual = residual + 0.5 * feedForward2(normFeedForward2(residual))
        return (normOut(residual), nextAttentionCache, nextConvCache)
    }
}

// MARK: - Encoder

final class NemotronASREncoder: Module {
    let config: NemotronASRConfig.Encoder
    let posEnc: ParakeetRelPositionalEncoding

    @ModuleInfo(key: "pre_encode") var preEncode: NemotronCausalSubsampling
    @ModuleInfo(key: "layers") var layers: [NemotronConformerBlock]

    init(config: NemotronASRConfig.Encoder) {
        self.config = config
        posEnc = ParakeetRelPositionalEncoding(dModel: config.dModel, maxLen: config.posEmbMaxLen, scaleInput: config.xscaling)
        _preEncode.wrappedValue = NemotronCausalSubsampling(config: config)
        _layers.wrappedValue = (0..<config.nLayers).map { _ in NemotronConformerBlock(config: config) }
    }
}

extension ParakeetRelPositionalEncoding {
    /// Relative positional embedding (`2 * length - 1` rows) for a key window of `length` frames.
    func embedding(length: Int, dtype: DType) -> MLXArray {
        let center = pe.shape[1] / 2
        return pe[0..., (center - (length - 1))..<(center + length), 0...].asType(dtype)
    }
}

// MARK: - Streaming State

/// Incremental cache-aware encoder state: subsampling runs over a small retained mel window,
/// and each conformer layer keeps `leftContext` attention-input frames and `kernel - 1`
/// convolution frames. Encoding is O(n) and matches the offline `chunked_limited` encoder at
/// the native chunk size (`rightContext + 1` frames).
final class NemotronEncoderStreamingState {
    /// At least the causal receptive field of the 8x dw-striding stack, in mel frames.
    private static let melCacheFrames = 16

    private let encoder: NemotronASREncoder
    private let leftContext: Int
    private let chunkMel: Int
    private let subsamplingFactor: Int
    private let inputScale: Float

    private var attentionCaches: [MLXArray?]
    private var convCaches: [MLXArray?]
    private var melCache: MLXArray?
    private var pending: MLXArray?
    private var emitted = 0
    private var consumed = 0

    init(encoder: NemotronASREncoder, attContextSize: [Int]) {
        self.encoder = encoder
        leftContext = attContextSize[0]
        subsamplingFactor = encoder.config.subsamplingFactor
        chunkMel = (attContextSize[1] + 1) * subsamplingFactor
        inputScale = encoder.config.xscaling ? sqrt(Float(encoder.config.dModel)) : 1
        attentionCaches = Array(repeating: nil, count: encoder.layers.count)
        convCaches = Array(repeating: nil, count: encoder.layers.count)
    }

    /// Appends `(1, T, F)` mel frames and returns the encoder chunks that became complete.
    /// Pass `final: true` with the last frames to flush the trailing partial chunk.
    func push(_ mel: MLXArray, final: Bool) -> [MLXArray] {
        if mel.shape[1] > 0 {
            pending = pending.map { MLX.concatenated([$0, mel], axis: 1) } ?? mel
        }
        var outputs: [MLXArray] = []
        while let buffered = pending, buffered.shape[1] > 0 {
            let available = buffered.shape[1]
            if available < chunkMel && !final { break }
            let take = min(chunkMel, available)
            let chunk = buffered[0..., ..<take, 0...]
            pending = buffered[0..., take..., 0...]
            let isLast = final && take == available
            if let encoded = encode(chunk, includeBoundary: isLast) {
                outputs.append(encoded)
            }
        }
        return outputs
    }

    private func encode(_ mel: MLXArray, includeBoundary: Bool) -> MLXArray? {
        let cacheLength = melCache?.shape[1] ?? 0
        let window = melCache.map { MLX.concatenated([$0, mel], axis: 1) } ?? mel
        let subsampled = encoder.preEncode(window)

        let end = consumed + mel.shape[1]
        let base = (consumed - cacheLength) / subsamplingFactor
        let lo = emitted - base
        let hi = includeBoundary ? subsampled.shape[1] : end / subsamplingFactor - base
        consumed = end

        let misalignment = ((end - Self.melCacheFrames) % subsamplingFactor + subsamplingFactor) % subsamplingFactor
        let keep = min(Self.melCacheFrames + misalignment, window.shape[1])
        melCache = window[0..., (window.shape[1] - keep)..., 0...]

        guard hi > lo else {
            emitted = base + max(lo, hi)
            return nil
        }
        emitted = base + hi

        var h = subsampled[0..., lo..<hi, 0...]
        if inputScale != 1 {
            h = h * inputScale
        }
        for (index, layer) in encoder.layers.enumerated() {
            let (output, attention, conv) = layer.step(
                h,
                attentionCache: attentionCaches[index],
                convCache: convCaches[index],
                leftContext: leftContext,
                posEnc: encoder.posEnc
            )
            h = output
            attentionCaches[index] = attention
            convCaches[index] = conv
        }
        eval([h, melCache!] + attentionCaches.compactMap { $0 } + convCaches.compactMap { $0 })
        return h
    }
}
