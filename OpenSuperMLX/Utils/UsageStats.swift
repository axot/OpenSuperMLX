//
//  UsageStats.swift
//  OpenSuperMLX
//
//  Pure aggregation of recording history into shareable usage stats:
//  per-language typing-speed percentile, streak, time saved, busiest day,
//  daily activity. All functions are pure and unit-testable; nothing reads
//  live UserDefaults or the database directly.
//

import Foundation

enum StatLanguage: String, CaseIterable {
    case chinese
    case english
    case japanese

    /// Distribution table: percentile → typing speed (units/min). Chinese & Japanese
    /// use chars/min; English uses words/min. Japanese reuses the Chinese table —
    /// CJK IME input produces comparable chars/min. Aggregated from public typing-test
    /// datasets (MonkeyType, TypeRacer published averages).
    var distribution: [(p: Int, speed: Double)] {
        switch self {
        case .english:
            return [(10, 20), (20, 28), (30, 33), (40, 38), (50, 42),
                    (60, 48), (70, 55), (80, 65), (90, 80), (95, 95), (99, 120)]
        case .chinese, .japanese:
            return [(10, 20), (20, 30), (30, 38), (40, 45), (50, 52),
                    (60, 60), (70, 70), (80, 82), (90, 100), (95, 120), (99, 160)]
        }
    }

    /// Conservative median typing rate (units/min) used for time-saved.
    var medianTypingRate: Double {
        switch self {
        case .english: return 42
        case .chinese, .japanese: return 52
        }
    }

    var displayName: String {
        switch self {
        case .chinese: return "Chinese"
        case .english: return "English"
        case .japanese: return "Japanese"
        }
    }
}

enum UsageStats {

    /// Minimum counted units (words or chars) for a language before a percentile is shown.
    static let minWordsForStats = 200

    // MARK: - Language detection

    /// Classify by dominant script over non-whitespace chars. All thresholds use `>=`.
    /// Returns nil for empty / punctuation-only text (skipped — not counted).
    static func detectLanguage(_ text: String) -> StatLanguage? {
        var kana = 0, han = 0, latin = 0, otherMeaningful = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if isHan(v) {
                han += 1
            } else if isKana(v) {
                kana += 1
            } else if isLatinLetter(v) {
                latin += 1
            } else if !isIgnorable(scalar) {
                otherMeaningful += 1
            }
        }
        let meaningful = kana + han + latin + otherMeaningful
        guard meaningful > 0 else { return nil }

        let denom = Double(meaningful)
        if kana > 0 && Double(kana + han) / denom >= 0.5 {
            return .japanese
        }
        if Double(han) / denom >= 0.5 {
            return .chinese
        }
        return .english
    }

    // MARK: - Unit counting

    /// Count the rate-relevant units for a language: Han-only (Chinese),
    /// Kana+Han (Japanese), letter-bearing whitespace tokens (English).
    static func countUnits(_ text: String, language: StatLanguage) -> Int {
        switch language {
        case .chinese:
            return text.unicodeScalars.filter { isHan($0.value) }.count
        case .japanese:
            return text.unicodeScalars.filter { isHan($0.value) || isKana($0.value) }.count
        case .english:
            return text.split(whereSeparator: \.isWhitespace)
                .filter { !$0.isEmpty && $0.contains(where: \.isLetter) }
                .count
        }
    }

    // MARK: - Percentile

    /// Highest representable percentile — i.e. "Top 0.01%". Bounds the elite tail.
    static let maxPercentile = 99.99

    /// Per-language typing-speed percentile for display, or nil if the language has
    /// fewer than `minWordsForStats` counted units across completed, positive-duration
    /// recordings of that language. Fractional so the elite tail (Top 0.1%, 0.01%) is
    /// distinguishable rather than flattened to "Top 1%".
    static func computePercentile(recordings: [Recording], language: StatLanguage) -> Double? {
        var totalUnits = 0
        var totalSeconds: TimeInterval = 0
        for r in recordings where r.status == .completed && r.duration > 0 {
            guard detectLanguage(r.transcription) == language else { continue }
            totalUnits += countUnits(r.transcription, language: language)
            totalSeconds += r.duration
        }
        guard totalUnits >= minWordsForStats, totalSeconds > 0 else { return nil }

        let rate = Double(totalUnits) / totalSeconds * 60.0
        return percentile(forRate: rate, language: language)
    }

    /// Map a typing rate to a percentile in [10, 99.99].
    /// - Within the table: linear interpolation between the bracketing points.
    /// - Above p99: extrapolate into the 99→99.99 tail. Each time the rate beats the
    ///   p99 speed by another (p95→p99) step, the remaining gap to 99.99 halves —
    ///   so genuinely fast typists reach Top 0.1% / 0.01%, but it never quite saturates.
    static func percentile(forRate rate: Double, language: StatLanguage) -> Double {
        let table = language.distribution
        guard let first = table.first, let last = table.last else { return 10 }
        if rate <= first.speed { return Double(first.p) }

        if rate >= last.speed {
            // Tail extrapolation above the p99 anchor.
            let p99 = Double(last.p)
            let step = max(1, last.speed - table[table.count - 2].speed) // p95→p99 span
            let over = (rate - last.speed) / step                        // steps beyond p99
            let remaining = maxPercentile - p99                          // 0.99
            let approached = 1 - pow(0.5, over)                          // 0→1 as over grows
            return min(maxPercentile, p99 + remaining * approached)
        }

        for i in 1..<table.count {
            let lo = table[i - 1], hi = table[i]
            if rate <= hi.speed {
                let t = (rate - lo.speed) / (hi.speed - lo.speed)
                return Double(lo.p) + t * Double(hi.p - lo.p)
            }
        }
        return Double(last.p)
    }

    /// Trim a "top %" value to a clean string: integers without decimals, otherwise
    /// up to two decimals with trailing zeros removed (5 → "5", 0.10 → "0.1").
    static func formatTop(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded.rounded()))
        }
        var s = String(format: "%.2f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: - Time saved

    /// Seconds saved vs. typing the same content at the median rate, floored at 0.
    /// Only completed, positive-duration recordings of `language` contribute.
    static func timeSaved(recordings: [Recording], language: StatLanguage) -> TimeInterval {
        var units = 0
        var spoken: TimeInterval = 0
        for r in recordings where r.status == .completed && r.duration > 0 {
            guard detectLanguage(r.transcription) == language else { continue }
            units += countUnits(r.transcription, language: language)
            spoken += r.duration
        }
        guard units > 0 else { return 0 }
        let typingSeconds = Double(units) / language.medianTypingRate * 60.0
        return max(0, typingSeconds - spoken)
    }

    /// Time saved across all languages combined.
    static func totalTimeSaved(recordings: [Recording]) -> TimeInterval {
        StatLanguage.allCases.reduce(0) { $0 + timeSaved(recordings: recordings, language: $1) }
    }

    // MARK: - Streak

    /// Consecutive calendar days (local tz, DST-safe) ending today with ≥1 completed
    /// recording. 0 if there is no completed recording today.
    static func currentStreak(recordings: [Recording], calendar: Calendar = .current, now: Date = Date()) -> Int {
        let days = Set(
            recordings
                .filter { $0.status == .completed }
                .map { calendar.startOfDay(for: $0.timestamp) }
        )
        var streak = 0
        var cursor = calendar.startOfDay(for: now)
        while days.contains(cursor) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    // MARK: - Busiest day

    /// Calendar day with the most completed recordings. Tie-break: most recent day.
    static func busiestDay(recordings: [Recording], calendar: Calendar = .current) -> Date? {
        var counts: [Date: Int] = [:]
        for r in recordings where r.status == .completed {
            let day = calendar.startOfDay(for: r.timestamp)
            counts[day, default: 0] += 1
        }
        return counts.max { a, b in
            a.value != b.value ? a.value < b.value : a.key < b.key
        }?.key
    }

    // MARK: - Activity by hour

    /// 24-element array: completed-recording count per local hour bucket [0, 23].
    static func activityByHour(recordings: [Recording], calendar: Calendar = .current) -> [Int] {
        var buckets = [Int](repeating: 0, count: 24)
        for r in recordings where r.status == .completed {
            let h = calendar.component(.hour, from: r.timestamp)
            if (0..<24).contains(h) { buckets[h] += 1 }
        }
        return buckets
    }

    // MARK: - Daily activity (contribution-graph style)

    /// Completed-recording count per calendar day, keyed by startOfDay. Used by the
    /// year contribution heatmap.
    static func dailyActivity(recordings: [Recording], calendar: Calendar = .current) -> [Date: Int] {
        var counts: [Date: Int] = [:]
        for r in recordings where r.status == .completed {
            counts[calendar.startOfDay(for: r.timestamp), default: 0] += 1
        }
        return counts
    }

    // MARK: - Aggregate counts

    static func totalUnits(recordings: [Recording]) -> Int {
        recordings
            .filter { $0.status == .completed }
            .reduce(0) { acc, r in
                guard let lang = detectLanguage(r.transcription) else { return acc }
                return acc + countUnits(r.transcription, language: lang)
            }
    }

    static func totalSpokenSeconds(recordings: [Recording]) -> TimeInterval {
        recordings
            .filter { $0.status == .completed && $0.duration.isFinite && $0.duration > 0 }
            .reduce(0) { $0 + $1.duration }
    }

    static func completedSessionCount(recordings: [Recording]) -> Int {
        recordings.filter { $0.status == .completed }.count
    }

    // MARK: - Scalar classifiers

    private static func isHan(_ v: UInt32) -> Bool { (0x4E00...0x9FFF).contains(v) }
    private static func isKana(_ v: UInt32) -> Bool { (0x3040...0x30FF).contains(v) }

    private static func isLatinLetter(_ v: UInt32) -> Bool {
        (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
    }

    /// Whitespace and punctuation are not meaningful script content for detection.
    private static func isIgnorable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace { return true }
        switch scalar.properties.generalCategory {
        case .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation,
             .connectorPunctuation, .dashPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
             .decimalNumber, .letterNumber, .otherNumber,
             .control, .format:
            return true
        default:
            return false
        }
    }
}
