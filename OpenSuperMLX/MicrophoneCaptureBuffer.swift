// MicrophoneCaptureBuffer.swift
// OpenSuperMLX

import Foundation
import Synchronization

final class MicrophoneCaptureBuffer: @unchecked Sendable {
    private let capacity: Int
    private let samples: UnsafeMutablePointer<Float>
    private let readIndex = Atomic<Int>(0)
    private let writeIndex = Atomic<Int>(0)
    private let active = Atomic<Bool>(false)
    private let generation = Atomic<UInt64>(0)
    private let requestedAt = Atomic<UInt64>(0)
    private let firstDeliveredAt = Atomic<UInt64>(0)
    private let lastDeliveredAt = Atomic<UInt64>(0)
    private let dropped = Atomic<Int>(0)
    private let callbacks = Atomic<Int>(0)
    private let rmsBits = Atomic<UInt32>(0)

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
    }

    deinit {
        samples.deinitialize(count: capacity)
        samples.deallocate()
    }

    // MARK: - Recording boundary

    var hasReceivedAudio: Bool {
        firstDeliveredAt.load(ordering: .acquiring) != 0
    }

    var isCapturing: Bool { active.load(ordering: .acquiring) }
    var sampleCount: Int {
        max(0, writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .relaxed))
    }

    var firstBufferLatencyMilliseconds: Double? {
        let delivered = firstDeliveredAt.load(ordering: .acquiring)
        guard delivered != 0 else { return nil }
        return Double(delivered - requestedAt.load(ordering: .relaxed)) / 1_000_000
    }

    var droppedSampleCount: Int { dropped.load(ordering: .relaxed) }
    var callbackCount: Int { callbacks.load(ordering: .relaxed) }
    var lastBufferDeliveryHostTime: UInt64 { lastDeliveredAt.load(ordering: .acquiring) }
    var rmsLevel: Float { Float(bitPattern: rmsBits.load(ordering: .relaxed)) }

    func begin(at hostTime: UInt64) {
        close()
        // The input is paused before resetting the single-producer/single-consumer indices.
        readIndex.store(0, ordering: .relaxed)
        writeIndex.store(0, ordering: .relaxed)
        requestedAt.store(hostTime, ordering: .relaxed)
        firstDeliveredAt.store(0, ordering: .relaxed)
        lastDeliveredAt.store(0, ordering: .relaxed)
        dropped.store(0, ordering: .relaxed)
        active.store(true, ordering: .releasing)
    }

    func close() {
        active.store(false, ordering: .releasing)
        _ = generation.wrappingAdd(1, ordering: .acquiringAndReleasing)
        rmsBits.store(0, ordering: .relaxed)
    }

    // MARK: - Audio I/O producer

    func receive(
        _ input: UnsafeBufferPointer<Float>,
        hostTime: UInt64,
        sampleRate: Double,
        deliveredAt: UInt64
    ) {
        _ = callbacks.wrappingAdd(1, ordering: .relaxed)
        guard active.load(ordering: .acquiring),
              !input.isEmpty, let source = input.baseAddress,
              sampleRate > 0, sampleRate.isFinite else { return }
        let epoch = generation.load(ordering: .acquiring)
        let requested = requestedAt.load(ordering: .relaxed)
        let skipped = hostTime < requested
            ? min(Double(input.count), ceil(Double(requested - hostTime) * sampleRate / 1_000_000_000))
            : 0
        let offset = Int(skipped)
        let count = input.count - offset
        guard count > 0 else { return }

        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let accepted = min(count, capacity - (write - read))
        guard accepted > 0 else {
            _ = dropped.wrappingAdd(count, ordering: .relaxed)
            return
        }
        let position = write % capacity
        let firstCount = min(accepted, capacity - position)
        samples.advanced(by: position).update(from: source.advanced(by: offset), count: firstCount)
        if firstCount < accepted {
            samples.update(from: source.advanced(by: offset + firstCount), count: accepted - firstCount)
        }
        guard active.load(ordering: .acquiring),
              generation.load(ordering: .acquiring) == epoch else { return }
        writeIndex.store(write + accepted, ordering: .releasing)
        if accepted < count {
            _ = dropped.wrappingAdd(count - accepted, ordering: .relaxed)
        }
        var sum: Float = 0
        for index in offset..<(offset + accepted) {
            sum += input[index] * input[index]
        }
        let rms = sqrt(sum / Float(accepted))
        rmsBits.store((rms.isFinite ? min(1, rms) : 0).bitPattern, ordering: .relaxed)
        lastDeliveredAt.store(deliveredAt, ordering: .releasing)
        if firstDeliveredAt.load(ordering: .relaxed) == 0 {
            firstDeliveredAt.store(deliveredAt, ordering: .releasing)
        }
    }

    // MARK: - Feed-loop consumer

    func drain() -> [Float] {
        let read = readIndex.load(ordering: .relaxed)
        let count = writeIndex.load(ordering: .acquiring) - read
        guard count > 0 else { return [] }
        let position = read % capacity
        let firstCount = min(count, capacity - position)
        let result = Array<Float>(unsafeUninitializedCapacity: count) { destination, initialized in
            destination.baseAddress!.initialize(from: samples.advanced(by: position), count: firstCount)
            if firstCount < count {
                destination.baseAddress!.advanced(by: firstCount)
                    .initialize(from: samples, count: count - firstCount)
            }
            initialized = count
        }
        readIndex.store(read + count, ordering: .releasing)
        return result
    }
}
