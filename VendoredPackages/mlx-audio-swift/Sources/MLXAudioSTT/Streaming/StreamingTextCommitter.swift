// StreamingTextCommitter.swift
// MLXAudioSTT

import Foundation

// MARK: - CommitResult

public struct CommitResult: Sendable {
    public let confirmedTokens: [Int]
    public let provisionalTokens: [Int]
    public let newlyEmittedTokens: [Int]
}

// MARK: - StreamingTextCommitter

public struct StreamingTextCommitter: Sendable {
    public let rollbackTokens: Int
    public let coldStartChunks: Int
    public let maxOverlapCheck: Int
    public let minOverlapMatch: Int

    public private(set) var rawTokens: [Int] = []
    public private(set) var stableTokens: [Int] = []
    public private(set) var emittedTokens: [Int] = []
    public private(set) var chunkCount: Int = 0

    public init(
        rollbackTokens: Int = 5,
        coldStartChunks: Int = 2,
        maxOverlapCheck: Int = 48,
        minOverlapMatch: Int = 4
    ) {
        self.rollbackTokens = rollbackTokens
        self.coldStartChunks = coldStartChunks
        self.maxOverlapCheck = maxOverlapCheck
        self.minOverlapMatch = minOverlapMatch
    }

    // MARK: - Process Chunk

    public mutating func processChunkTokens(_ newTokens: [Int], isFinal: Bool) -> CommitResult {
        chunkCount += 1
        rawTokens = newTokens

        if isFinal {
            let all = rawTokens
            let delta = findDelta(from: emittedTokens, to: all)
            stableTokens = all
            emittedTokens = all
            return CommitResult(
                confirmedTokens: all,
                provisionalTokens: [],
                newlyEmittedTokens: delta
            )
        }

        if chunkCount <= coldStartChunks {
            return CommitResult(
                confirmedTokens: [],
                provisionalTokens: rawTokens,
                newlyEmittedTokens: []
            )
        }

        let splitPoint = max(0, rawTokens.count - rollbackTokens)
        let candidateTokens = Array(rawTokens.prefix(splitPoint))
        let provisionalTokens = Array(rawTokens.suffix(from: splitPoint))

        stableTokens = candidateTokens

        let delta = findDelta(from: emittedTokens, to: candidateTokens)
        emittedTokens = candidateTokens

        return CommitResult(
            confirmedTokens: candidateTokens,
            provisionalTokens: provisionalTokens,
            newlyEmittedTokens: delta
        )
    }

    // MARK: - Reanchor

    public mutating func reanchor(from emitted: [Int], keepLast: Int) {
        let kept = Array(emitted.suffix(keepLast))
        rawTokens = kept
        stableTokens = kept
        emittedTokens = emitted
    }

    // MARK: - Private

    private func findDelta(from emitted: [Int], to newStable: [Int]) -> [Int] {
        guard !newStable.isEmpty else { return [] }
        guard !emitted.isEmpty else { return newStable }

        let prefixLen = commonPrefixLength(emitted, newStable)
        if prefixLen == emitted.count {
            return Array(newStable.suffix(from: prefixLen))
        }

        let maxCheck = min(maxOverlapCheck, emitted.count, newStable.count)
        for overlapLen in stride(from: maxCheck, through: minOverlapMatch, by: -1) {
            let emittedTail = emitted.suffix(overlapLen)
            let newHead = newStable.prefix(overlapLen)
            if Array(emittedTail) == Array(newHead) {
                return Array(newStable.suffix(from: overlapLen))
            }
        }

        if newStable.count > emitted.count,
           Array(newStable.prefix(emitted.count)) == emitted {
            return Array(newStable.suffix(from: emitted.count))
        }

        return newStable
    }

    private func commonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        let limit = min(a.count, b.count)
        for i in 0..<limit {
            if a[i] != b[i] { return i }
        }
        return limit
    }
}
