//
//  Qwen3ASRCoreMLAudioTower.swift
//  MLXAudioSTT
//

import CoreML
import Foundation
import MLX
import os

public enum Qwen3ASRCoreMLAudioTowerError: Error {
    case loadFailed(Error)
    case invalidOutput
}

/// Runs the Qwen3-ASR audio tower as a Core ML program so it can execute on the Neural Engine.
///
/// The program encodes one fixed 800-frame window: `mel` is `[1, nMels, 800]` (zero-padded after
/// the valid frames) and `length` is the number of valid output tokens. It returns
/// `audio_features` `[1, 104, outputDim]`. Padded frames sit in the same 100-frame conv chunks the
/// MLX encoder uses and padded tokens are masked out of attention, so the first `length` tokens
/// match the MLX encoder.
public final class Qwen3ASRCoreMLAudioTower {
    static let framesPerChunk = 100
    static let tokensPerChunk = 13
    static let windowFrames = 800

    private static let logger = Logger(subsystem: "OpenSuperMLX", category: "Qwen3ASRCoreMLAudioTower")

    private let model: MLModel
    private let melBins: Int

    /// Loads the program and runs one silent window so Neural Engine compilation happens here
    /// rather than during the first recording.
    public init(url: URL, melBins: Int, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let compiledURL = url.pathExtension == "mlpackage" ? try MLModel.compileModel(at: url) : url
        model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        self.melBins = melBins
        _ = try encodeWindow(MLXArray.zeros([Self.windowFrames, melBins]))
        Self.logger.info("Loaded Core ML audio tower from \(url.path, privacy: .public)")
    }

    // MARK: - Window Layout

    static func tokenCount(chunkFrames: Int) -> Int {
        guard chunkFrames > 0 else { return 0 }
        var length = chunkFrames
        for _ in 0..<3 {
            length = (length - 1) / 2 + 1
        }
        return length
    }

    static func validTokenCount(frames: Int) -> Int {
        frames / framesPerChunk * tokensPerChunk + tokenCount(chunkFrames: frames % framesPerChunk)
    }

    static func windowRanges(frames: Int) -> [Range<Int>] {
        stride(from: 0, to: frames, by: windowFrames).map { $0..<min($0 + windowFrames, frames) }
    }

    // MARK: - Encoding

    /// Encodes `[numFrames, nMels]` mel frames (numFrames ≤ 800) into `[validTokens, outputDim]`.
    func encodeWindow(_ melFrames: MLXArray) throws -> MLXArray {
        let frames = melFrames.dim(0)
        precondition(frames > 0 && frames <= Self.windowFrames, "window must hold 1...800 mel frames")
        precondition(melFrames.dim(1) == melBins, "expected \(melBins) mel bins")

        let validTokens = Self.validTokenCount(frames: frames)
        let values = melFrames.asArray(Float.self)
        return try autoreleasepool {
            let mel = try MLMultiArray(
                shape: [1, NSNumber(value: melBins), NSNumber(value: Self.windowFrames)],
                dataType: .float32
            )
            let melPointer = mel.dataPointer.assumingMemoryBound(to: Float.self)
            melPointer.initialize(repeating: 0, count: melBins * Self.windowFrames)
            for frame in 0..<frames {
                for bin in 0..<melBins {
                    melPointer[bin * Self.windowFrames + frame] = values[frame * melBins + bin]
                }
            }
            let length = try MLMultiArray(shape: [1], dataType: .int32)
            length[0] = NSNumber(value: validTokens)

            let input = try MLDictionaryFeatureProvider(dictionary: [
                "mel": MLFeatureValue(multiArray: mel),
                "length": MLFeatureValue(multiArray: length),
            ])
            let output = try model.prediction(from: input)
            guard let features = output.featureValue(for: "audio_features")?.multiArrayValue else {
                throw Qwen3ASRCoreMLAudioTowerError.invalidOutput
            }
            return try Self.validRows(of: features, count: validTokens)
        }
    }

    /// Mirrors `Qwen3ASRAudioEncoder.callAsFunction`: each item is split into 800-frame windows
    /// whose block attention never crosses a window boundary.
    func encode(features: MLXArray, lengths: [Int]) throws -> MLXArray {
        var outputs: [MLXArray] = []
        for (index, length) in lengths.enumerated() {
            let frames = features[index][0..., 0..<length].transposed(1, 0)
            for range in Self.windowRanges(frames: length) {
                outputs.append(try encodeWindow(frames[range]))
            }
        }
        return MLX.concatenated(outputs, axis: 0)
    }

    private static func validRows(of features: MLMultiArray, count: Int) throws -> MLXArray {
        guard features.shape.count == 3, features.shape[1].intValue >= count else {
            throw Qwen3ASRCoreMLAudioTowerError.invalidOutput
        }
        let width = features.shape[2].intValue
        let rowStride = features.strides[1].intValue
        let columnStride = features.strides[2].intValue
        var values = [Float](repeating: 0, count: count * width)

        switch features.dataType {
        case .float32:
            let source = features.dataPointer.assumingMemoryBound(to: Float.self)
            for row in 0..<count {
                for column in 0..<width {
                    values[row * width + column] = source[row * rowStride + column * columnStride]
                }
            }
        case .float16:
            let source = features.dataPointer.assumingMemoryBound(to: Float16.self)
            for row in 0..<count {
                for column in 0..<width {
                    values[row * width + column] = Float(source[row * rowStride + column * columnStride])
                }
            }
        default:
            throw Qwen3ASRCoreMLAudioTowerError.invalidOutput
        }
        return MLXArray(values, [count, width]).asType(.bfloat16)
    }
}
