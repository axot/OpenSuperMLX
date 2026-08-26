// PCMRetryBuffer.swift
// OpenSuperMLX

import Foundation

struct PCMRetryBuffer: Sendable {
    private(set) var samples: [Int16] = []

    var count: Int { samples.count }
    var byteCount: Int { samples.count * MemoryLayout<Int16>.stride }
    var isEmpty: Bool { samples.isEmpty }

    mutating func append(_ floatSamples: [Float]) {
        samples.reserveCapacity(samples.count + floatSamples.count)
        for sample in floatSamples {
            let clipped = sample.isFinite ? min(max(sample, -1), 1) : 0
            if clipped == -1 {
                samples.append(.min)
            } else {
                samples.append(Int16((clipped * Float(Int16.max)).rounded()))
            }
        }
    }

    func decodedSamples() -> [Float] {
        samples.map { sample in
            sample == .min ? -1 : Float(sample) / Float(Int16.max)
        }
    }

    mutating func release() {
        samples.removeAll(keepingCapacity: false)
    }
}
