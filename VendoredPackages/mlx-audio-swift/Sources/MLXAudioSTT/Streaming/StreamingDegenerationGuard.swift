// StreamingDegenerationGuard.swift
// MLXAudioSTT

import Foundation

// MARK: - GuardAction

enum GuardAction: Sendable, Equatable {
    case ok(filteredNewTokens: [Int])
    case recoveryReset
}

// MARK: - StreamingDegenerationGuard

struct StreamingDegenerationGuard: Sendable {
    let maxSingleTokenRun: Int
    let blockPatternMaxPeriod: Int
    let blockPatternMinReps: Int
    let stagnationThreshold: Int
    let droppedTokensRecovery: Int

    private(set) var stagnantChunkCount: Int = 0

    init(
        maxSingleTokenRun: Int = 12,
        blockPatternMaxPeriod: Int = 6,
        blockPatternMinReps: Int = 4,
        stagnationThreshold: Int = 4,
        droppedTokensRecovery: Int = 8
    ) {
        self.maxSingleTokenRun = maxSingleTokenRun
        self.blockPatternMaxPeriod = blockPatternMaxPeriod
        self.blockPatternMinReps = blockPatternMinReps
        self.stagnationThreshold = stagnationThreshold
        self.droppedTokensRecovery = droppedTokensRecovery
    }

    // MARK: - Public API

    mutating func evaluateChunk(
        prefixTokens: [Int],
        newChunkTokens: [Int],
        stableTokenCount: Int,
        hitMaxTokens: Bool,
        isFinal: Bool
    ) -> GuardAction {
        let (filteredNew, droppedCount) = suppressSingleTokenRuns(
            prefixTokens: prefixTokens,
            newChunkTokens: newChunkTokens
        )

        if droppedCount >= droppedTokensRecovery {
            stagnantChunkCount = 0
            return .recoveryReset
        }

        let candidateTokens = prefixTokens + filteredNew
        if hasBlockPattern(candidateTokens) {
            stagnantChunkCount = 0
            return .recoveryReset
        }

        let candidateAdvance = candidateTokens.count - stableTokenCount
        if !isFinal && hitMaxTokens && candidateAdvance <= 1 {
            stagnantChunkCount += 1
            if stagnantChunkCount >= stagnationThreshold {
                stagnantChunkCount = 0
                return .recoveryReset
            }
        } else {
            stagnantChunkCount = 0
        }

        return .ok(filteredNewTokens: filteredNew)
    }

    mutating func resetStagnation() {
        stagnantChunkCount = 0
    }

    // MARK: - Layer 1: Single-token run suppression

    private func suppressSingleTokenRuns(
        prefixTokens: [Int],
        newChunkTokens: [Int]
    ) -> (filtered: [Int], droppedCount: Int) {
        guard !newChunkTokens.isEmpty else { return ([], 0) }

        var prevTok = -1
        var prevRun = 0
        if !prefixTokens.isEmpty {
            prevTok = prefixTokens[prefixTokens.count - 1]
            prevRun = 1
            for j in stride(from: prefixTokens.count - 2, through: 0, by: -1) {
                if prefixTokens[j] != prevTok { break }
                prevRun += 1
                if prevRun >= maxSingleTokenRun { break }
            }
        }

        var filtered: [Int] = []
        filtered.reserveCapacity(newChunkTokens.count)
        var droppedCount = 0

        for tok in newChunkTokens {
            if tok == prevTok {
                prevRun += 1
                if prevRun > maxSingleTokenRun {
                    droppedCount += 1
                    continue
                }
            } else {
                prevTok = tok
                prevRun = 1
            }
            filtered.append(tok)
        }

        return (filtered, droppedCount)
    }

    // MARK: - Layer 2: Block pattern detection

    private func hasBlockPattern(_ tokens: [Int]) -> Bool {
        guard blockPatternMaxPeriod >= 2 else { return false }
        for period in 2...blockPatternMaxPeriod {
            let requiredLength = period * blockPatternMinReps
            guard tokens.count >= requiredLength else { continue }

            let tail = tokens.suffix(requiredLength)
            let startIndex = tail.startIndex
            let pattern = Array(tail[startIndex..<startIndex + period])

            guard Set(pattern).count > 1 else { continue }

            var allMatch = true
            for rep in 1..<blockPatternMinReps {
                let offset = startIndex + rep * period
                let slice = Array(tail[offset..<offset + period])
                if slice != pattern {
                    allMatch = false
                    break
                }
            }

            if allMatch { return true }
        }

        return false
    }
}
