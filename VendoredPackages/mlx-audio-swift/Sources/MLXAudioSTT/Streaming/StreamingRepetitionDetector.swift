// StreamingRepetitionDetector.swift
// MLXAudioSTT

import Foundation

// MARK: - Match

struct StreamingRepetitionMatch: Equatable, Sendable {
    let historyRange: Range<Int>
    let queryRange: Range<Int>
    let edits: Int
    let utf8Bytes: Int

    fileprivate func precedes(_ other: Self) -> Bool {
        (queryRange.upperBound, queryRange.lowerBound, historyRange.upperBound,
         historyRange.lowerBound, edits)
            < (other.queryRange.upperBound, other.queryRange.lowerBound, other.historyRange.upperBound,
               other.historyRange.lowerBound, other.edits)
    }
}

// MARK: - Detector

struct StreamingRepetitionDetector: Sendable {
    private struct Path: Sendable {
        let cost: Int
        let start: Int
        let edits: Int

        func adding(cost: Int, edits: Int) -> Self {
            Self(cost: self.cost + cost, start: start, edits: self.edits + edits)
        }

        static func best(_ a: Self, _ b: Self, _ c: Self) -> Self {
            let first = (a.cost, a.start, a.edits) < (b.cost, b.start, b.edits) ? a : b
            return (first.cost, first.start, first.edits) < (c.cost, c.start, c.edits) ? first : c
        }
    }

    private struct Cell: Sendable {
        let historyBudget: Path
        let queryBudget: Path

        static func boundary(length: Int, start: Int = 0) -> Self {
            let path = Path(cost: 20 * length, start: start, edits: length)
            return Self(historyBudget: path, queryBudget: path)
        }

        static func next(diagonal: Self, above: Self, previous: Self, mismatch: Int) -> Self {
            Self(
                historyBudget: .best(
                    diagonal.historyBudget.adding(cost: 20 * mismatch - 3, edits: mismatch),
                    above.historyBudget.adding(cost: 17, edits: 1),
                    previous.historyBudget.adding(cost: 20, edits: 1)
                ),
                queryBudget: .best(
                    diagonal.queryBudget.adding(cost: 20 * mismatch, edits: mismatch),
                    above.queryBudget.adding(cost: 20, edits: 1),
                    previous.queryBudget.adding(cost: 20, edits: 1)
                )
            )
        }
    }

    private let minimumBytes: Int
    private let maximumCachedCells: Int
    private var history: [Unicode.Scalar] = []
    private var query: [Unicode.Scalar] = []
    private var bytePrefix: [Int] = [0]
    private var columns: [[[Cell]]] = [[]]
    private var columnMatches: [StreamingRepetitionMatch?] = [nil]
    private var prefixMatches: [StreamingRepetitionMatch?] = [nil]
    private var firstCachedColumn = 1
    private var usedFallback = false
    private var fallbackMatch: StreamingRepetitionMatch?
    private(set) var computedCells = 0
    private(set) var retainedCells = 0

    init(minimumBytes: Int = 48, maximumCachedCells: Int = 250_000) {
        precondition(minimumBytes > 0 && maximumCachedCells >= 0)
        self.minimumBytes = minimumBytes
        self.maximumCachedCells = maximumCachedCells
    }

    // MARK: - Updates

    mutating func reset() {
        history = []
        query = []
        bytePrefix = [0]
        columns = [[]]
        columnMatches = [nil]
        prefixMatches = [nil]
        firstCachedColumn = 1
        usedFallback = false
        fallbackMatch = nil
        computedCells = 0
        retainedCells = 0
    }

    mutating func update(history historyText: String, query queryText: String) -> StreamingRepetitionMatch? {
        let newHistory = Array(Self.normalize(historyText).unicodeScalars)
        let newQuery = Array(Self.normalize(queryText).unicodeScalars)
        computedCells = 0
        if usedFallback {
            if newHistory == history && newQuery == query { return fallbackMatch }
            reset()
        }
        guard !newHistory.isEmpty && !newQuery.isEmpty else {
            reset()
            return nil
        }
        if newQuery.count > maximumCachedCells / (newHistory.count + 1) {
            reset()
            let match = scan(history: newHistory, query: newQuery)
            history = newHistory
            query = newQuery
            usedFallback = true
            fallbackMatch = match
            return match
        }

        if !newHistory.starts(with: history) { reset() }
        var sharedQueryLength = zip(query, newQuery).prefix(while: { $0 == $1 }).count
        let sharedColumnWasEvicted = sharedQueryLength > 0 && columns[sharedQueryLength].isEmpty
        if sharedColumnWasEvicted
            || (newHistory.count > history.count && (firstCachedColumn > 1
                || sharedQueryLength * (sharedQueryLength + 1) / 2
                    > maximumCachedCells / (newHistory.count + 1))) {
            reset()
            sharedQueryLength = 0
        }
        let oldHistoryCount = history.count
        columns.removeSubrange((sharedQueryLength + 1)..<columns.count)
        columnMatches.removeSubrange((sharedQueryLength + 1)..<columnMatches.count)
        prefixMatches.removeSubrange((sharedQueryLength + 1)..<prefixMatches.count)
        retainedCells = columns.reduce(0) { $0 + $1.count * (oldHistoryCount + 1) }
        if sharedQueryLength == 0 { firstCachedColumn = 1 }
        history = newHistory
        query = newQuery
        bytePrefix = Self.byteOffsets(query)

        if history.count > oldHistoryCount && sharedQueryLength > 0 {
            for j in 1...sharedQueryLength {
                for b in 0..<j {
                    columns[j][b].append(contentsOf: repeatElement(
                        .boundary(length: 0), count: history.count - oldHistoryCount
                    ))
                }
            }
            for i in (oldHistoryCount + 1)...history.count {
                for j in 1...sharedQueryLength {
                    for b in 0..<j { compute(i: i, j: j, b: b) }
                }
            }
            for j in 1...sharedQueryLength {
                prefixMatches[j] = Self.earlier(prefixMatches[j - 1], columnMatches[j])
            }
            retainedCells += (history.count - oldHistoryCount) * sharedQueryLength * (sharedQueryLength + 1) / 2
        }
        if sharedQueryLength < query.count {
            for j in (sharedQueryLength + 1)...query.count {
                appendColumn(j)
                prefixMatches.append(Self.earlier(prefixMatches[j - 1], columnMatches[j]))
                retainedCells += j * (history.count + 1)
                while retainedCells > maximumCachedCells && firstCachedColumn < j {
                    retainedCells -= columns[firstCachedColumn].count * (history.count + 1)
                    columns[firstCachedColumn] = []
                    firstCachedColumn += 1
                }
            }
        }
        return prefixMatches.last!
    }

    private mutating func appendColumn(_ j: Int) {
        var column: [[Cell]] = []
        var best: StreamingRepetitionMatch?
        let character = query[j - 1]
        for b in 0..<j {
            let previous = b == j - 1 ? [] : columns[j - 1][b]
            let byteCount = bytePrefix[j] - bytePrefix[b]
            var rows = Array(repeating: Cell.boundary(length: j - b), count: history.count + 1)
            rows.withUnsafeMutableBufferPointer { current in
                for i in 1...history.count {
                    let diagonal = previous.isEmpty ? Cell.boundary(length: 0, start: i - 1) : previous[i - 1]
                    let left = previous.isEmpty ? Cell.boundary(length: 0, start: i) : previous[i]
                    let cell = Cell.next(
                        diagonal: diagonal, above: current[i - 1], previous: left,
                        mismatch: history[i - 1] == character ? 0 : 1
                    )
                    current[i] = cell
                    if byteCount >= minimumBytes,
                       let candidate = match(cell, i: i, j: j, b: b, byteCount: byteCount) {
                        best = Self.earlier(best, candidate)
                    }
                }
            }
            column.append(rows)
        }
        columns.append(column)
        columnMatches.append(best)
        computedCells += history.count * j
    }

    private mutating func compute(i: Int, j: Int, b: Int) {
        let diagonal = b == j - 1 ? Cell.boundary(length: 0, start: i - 1) : columns[j - 1][b][i - 1]
        let previous = b == j - 1 ? Cell.boundary(length: 0, start: i) : columns[j - 1][b][i]
        let cell = Cell.next(
            diagonal: diagonal, above: columns[j][b][i - 1], previous: previous,
            mismatch: history[i - 1] == query[j - 1] ? 0 : 1
        )
        columns[j][b][i] = cell
        computedCells += 1
        if let candidate = match(cell, i: i, j: j, b: b, byteCount: bytePrefix[j] - bytePrefix[b]) {
            columnMatches[j] = Self.earlier(columnMatches[j], candidate)
        }
    }

    // MARK: - Bounded Memory Fallback

    private mutating func scan(history: [Unicode.Scalar], query: [Unicode.Scalar]) -> StreamingRepetitionMatch? {
        guard !history.isEmpty && !query.isEmpty else { return nil }
        let bytes = Self.byteOffsets(query)
        var best: StreamingRepetitionMatch?
        for b in query.indices {
            var previous = (0...history.count).map { Cell.boundary(length: 0, start: $0) }
            var current = previous
            for j in (b + 1)...query.count {
                if let best, j > best.queryRange.upperBound { break }
                let byteCount = bytes[j] - bytes[b]
                current[0] = .boundary(length: j - b)
                for i in 1...history.count {
                    current[i] = Cell.next(
                        diagonal: previous[i - 1], above: current[i - 1], previous: previous[i],
                        mismatch: history[i - 1] == query[j - 1] ? 0 : 1
                    )
                    computedCells += 1
                    if byteCount >= minimumBytes,
                       let candidate = match(current[i], i: i, j: j, b: b, byteCount: byteCount) {
                        best = Self.earlier(best, candidate)
                    }
                }
                swap(&previous, &current)
            }
        }
        return best
    }

    private func match(_ cell: Cell, i: Int, j: Int, b: Int, byteCount: Int) -> StreamingRepetitionMatch? {
        guard byteCount >= minimumBytes else { return nil }
        // 20e <= 3 max(h, q) iff 20e - 3h <= 0 or 20e <= 3q.
        var result: StreamingRepetitionMatch?
        if cell.historyBudget.cost <= 0 {
            result = StreamingRepetitionMatch(
                historyRange: cell.historyBudget.start..<i, queryRange: b..<j,
                edits: cell.historyBudget.edits, utf8Bytes: byteCount
            )
        }
        if cell.queryBudget.cost <= 3 * (j - b) {
            result = Self.earlier(result, StreamingRepetitionMatch(
                historyRange: cell.queryBudget.start..<i, queryRange: b..<j,
                edits: cell.queryBudget.edits, utf8Bytes: byteCount
            ))
        }
        return result
    }

    private static func earlier(
        _ a: StreamingRepetitionMatch?, _ b: StreamingRepetitionMatch?
    ) -> StreamingRepetitionMatch? {
        guard let a else { return b }
        guard let b else { return a }
        return a.precedes(b) ? a : b
    }

    // MARK: - Unicode

    static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        // Foundation's case-insensitive folding differs from full Unicode casefold for these scalars.
        let scalars = folded.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.value {
            case 0xAB70...0xABBF: return Unicode.Scalar(scalar.value - 0xAB70 + 0x13A0)!
            case 0x13F8...0x13FD: return Unicode.Scalar(scalar.value - 8)!
            case 0x1C80...0x1C88:
                let mappings: [UInt32] = [0x432, 0x434, 0x43E, 0x441, 0x442, 0x442, 0x44A, 0x463, 0xA64B]
                return Unicode.Scalar(mappings[Int(scalar.value - 0x1C80)])!
            default: return scalar
            }
        }
        return String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping
    }

    private static func byteOffsets(_ scalars: [Unicode.Scalar]) -> [Int] {
        var offsets = [0]
        offsets.reserveCapacity(scalars.count + 1)
        for scalar in scalars {
            offsets.append(offsets.last! + scalar.utf8.count)
        }
        return offsets
    }
}
