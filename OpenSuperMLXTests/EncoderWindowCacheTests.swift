// EncoderWindowCacheTests.swift
// OpenSuperMLXTests

import XCTest

import MLX
@testable import MLXAudioSTT

final class EncoderWindowCacheTests: XCTestCase {

    private let hiddenDim = 896

    // MARK: - Add Window

    func testAddWindow() {
        var cache = EncoderWindowCache()
        let output = MLXArray.zeros([100, hiddenDim])
        cache.addWindow(CachedWindow(encoderOutput: output, seqLen: 100, startMelFrame: 0))

        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.totalSeqLen, 100)
    }

    // MARK: - FIFO Eviction

    func testMaxFourWindows() {
        var cache = EncoderWindowCache()
        for i in 0..<5 {
            let output = MLXArray.zeros([100, hiddenDim])
            cache.addWindow(CachedWindow(encoderOutput: output, seqLen: 100, startMelFrame: i * 800))
        }

        XCTAssertEqual(cache.count, 4)
        XCTAssertEqual(cache.totalSeqLen, 400)
    }

    // MARK: - Concatenation

    func testConcatenateOutputs() {
        var cache = EncoderWindowCache()
        cache.addWindow(CachedWindow(encoderOutput: MLXArray.zeros([100, hiddenDim]), seqLen: 100, startMelFrame: 0))
        cache.addWindow(CachedWindow(encoderOutput: MLXArray.zeros([150, hiddenDim]), seqLen: 150, startMelFrame: 800))
        cache.addWindow(CachedWindow(encoderOutput: MLXArray.zeros([200, hiddenDim]), seqLen: 200, startMelFrame: 1600))

        let concatenated = cache.concatenatedOutput()
        XCTAssertNotNil(concatenated)
        XCTAssertEqual(concatenated!.shape, [450, hiddenDim])
    }

    // MARK: - Eviction Order

    func testEvictionOrder() {
        var cache = EncoderWindowCache()
        for i in 0..<5 {
            let output = MLXArray.zeros([100, hiddenDim])
            cache.addWindow(CachedWindow(encoderOutput: output, seqLen: 100, startMelFrame: i * 800))
        }

        XCTAssertEqual(cache.windows.first?.startMelFrame, 800)
        XCTAssertEqual(cache.windows.last?.startMelFrame, 3200)
    }

    // MARK: - Empty Cache

    func testEmptyCache() {
        let cache = EncoderWindowCache()

        XCTAssertEqual(cache.count, 0)
        XCTAssertTrue(cache.isEmpty)
        XCTAssertNil(cache.concatenatedOutput())
    }

    // MARK: - Clear

    func testClear() {
        var cache = EncoderWindowCache()
        cache.addWindow(CachedWindow(encoderOutput: MLXArray.zeros([100, hiddenDim]), seqLen: 100, startMelFrame: 0))
        cache.addWindow(CachedWindow(encoderOutput: MLXArray.zeros([150, hiddenDim]), seqLen: 150, startMelFrame: 800))

        cache.clear()

        XCTAssertEqual(cache.count, 0)
        XCTAssertTrue(cache.isEmpty)
        XCTAssertNil(cache.concatenatedOutput())
    }
}
