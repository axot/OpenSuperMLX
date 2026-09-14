// StreamingAudioTimeline.swift
// MLXAudioSTT

struct StreamingAudioTimeline {
    private struct Offset {
        let inputSample: Int
        let skippedSamples: Int
    }

    private let sourceSampleLimit: Int?
    private var inputSamples = 0
    private var skippedSamples = 0
    private var offsets = [Offset(inputSample: 0, skippedSamples: 0)]

    var offsetCount: Int { offsets.count }

    init(sourceSampleLimit: Int? = nil) {
        self.sourceSampleLimit = sourceSampleLimit
    }

    mutating func append(sampleCount: Int, skippedSamples: Int) {
        if skippedSamples > 0 {
            self.skippedSamples += skippedSamples
            offsets.append(Offset(inputSample: inputSamples, skippedSamples: self.skippedSamples))
        }
        inputSamples += sampleCount
    }

    func sourceRange(for inputRange: Range<Int>) -> Range<Int> {
        let lower = min(inputRange.lowerBound, inputSamples)
        let upper = min(inputRange.upperBound, inputSamples)
        let lowerOffset = offsets.last { $0.inputSample <= lower }?.skippedSamples ?? 0
        let upperOffset = offsets.last { $0.inputSample < upper }?.skippedSamples ?? 0
        let limit = sourceSampleLimit ?? (inputSamples + skippedSamples)
        let start = min(lower + lowerOffset, limit)
        let end = min(upper + upperOffset, limit)
        return start..<max(start, end)
    }

    mutating func discardOffsets(before inputSample: Int) {
        guard let index = offsets.lastIndex(where: { $0.inputSample < inputSample }) else { return }
        offsets.removeFirst(index)
    }
}
