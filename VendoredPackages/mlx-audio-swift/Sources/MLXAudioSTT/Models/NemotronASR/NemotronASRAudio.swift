import Foundation
import MLX
import MLXAudioCore

/// NeMo `AudioToMelSpectrogramPreprocessor` at inference: preemphasis, centered STFT with
/// reflect padding and a symmetric Hann window, power spectrum, Slaney mel filters, and
/// `log(x + guard)`. Nemotron 3.5 uses `normalize: NA`, so features are not normalized.
struct NemotronASRAudio {
    let config: NemotronASRConfig.Preprocessor
    private let window: MLXArray
    private let filters: MLXArray

    init(config: NemotronASRConfig.Preprocessor) {
        self.config = config
        let hann = hanningWindow(size: config.winLength)
        let left = (config.nFft - config.winLength) / 2
        let right = config.nFft - config.winLength - left
        self.window = MLX.concatenated([MLXArray.zeros([left]), hann, MLXArray.zeros([right])])
        self.filters = melFilters(
            sampleRate: config.sampleRate,
            nFft: config.nFft,
            nMels: config.features,
            norm: "slaney",
            melScale: .slaney
        )
    }

    func frameCount(samples: Int) -> Int {
        samples / config.hopLength + 1
    }

    func preemphasize(_ audio: MLXArray) -> MLXArray {
        guard config.preemph > 0, audio.shape[0] > 1 else { return audio }
        let rest = audio[1...] - Float(config.preemph) * audio[..<(audio.shape[0] - 1)]
        return MLX.concatenated([audio[0..<1], rest], axis: 0)
    }

    /// Log-mel frames `[frameStart, frameEnd)` of a preemphasized waveform, identical to the same
    /// range of a full-utterance pass. Returns `(1, frames, features)`.
    func logMel(preemphasized x: MLXArray, frameStart: Int, frameEnd: Int) -> MLXArray {
        let hop = config.hopLength
        let nFft = config.nFft
        let total = x.shape[0]
        let numFrames = frameEnd - frameStart
        let sampleStart = frameStart * hop - nFft / 2
        let sampleEnd = (frameEnd - 1) * hop - nFft / 2 + nFft

        let raw = x[max(sampleStart, 0)..<min(sampleEnd, total)]
        var pieces: [MLXArray] = []
        let leftPad = max(-sampleStart, 0)
        if leftPad > 0 {
            pieces.append(Self.reversed(raw[1..<(leftPad + 1)]))
        }
        pieces.append(raw)
        let rightPad = max(sampleEnd - total, 0)
        if rightPad > 0 {
            let count = raw.shape[0]
            pieces.append(Self.reversed(raw[(count - rightPad - 1)..<(count - 1)]))
        }
        var segment = pieces.count > 1 ? MLX.concatenated(pieces, axis: 0) : raw

        let expectedLength = (numFrames - 1) * hop + nFft
        if segment.shape[0] < expectedLength {
            segment = MLX.concatenated([segment, MLXArray.zeros([expectedLength - segment.shape[0]])])
        }

        let frames = asStrided(segment, [numFrames, nFft], strides: [hop, 1], offset: 0)
        let power = MLX.abs(MLXFFT.rfft(frames * window, axis: 1)).square()
        let mel = MLX.log(MLX.matmul(power, filters) + Float(config.logZeroGuardValue))
        return mel.expandedDimensions(axis: 0)
    }

    private static func reversed(_ x: MLXArray) -> MLXArray {
        let count = x.shape[0]
        return x[MLXArray((0..<count).reversed().map { Int32($0) })]
    }
}
