//
//  UsageStatsTests.swift
//  OpenSuperMLXTests
//
//  Tests pure stats computation: language detection, percentile,
//  time-saved, streak, busiest day, activity buckets, word/char counting.
//

import XCTest
@testable import OpenSuperMLX

final class UsageStatsTests: XCTestCase {

    private func rec(_ text: String, duration: TimeInterval = 10, daysAgo: Int = 0,
                     hour: Int = 12, status: RecordingStatus = .completed,
                     calendar: Calendar = .current, now: Date = Date()) -> Recording {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        let base = calendar.date(from: comps) ?? now
        let ts = calendar.date(byAdding: .day, value: -daysAgo, to: base) ?? now
        return Recording(id: UUID(), timestamp: ts, fileName: "f.wav", transcription: text,
                         duration: duration, status: status, progress: 1, sourceFileURL: nil)
    }

    // MARK: - Language detection

    func testDetectChinese() {
        XCTAssertEqual(UsageStats.detectLanguage("你好世界今天天气很好"), .chinese)
    }

    func testDetectJapaneseWhenKanaPresent() {
        XCTAssertEqual(UsageStats.detectLanguage("これはテストです日本語"), .japanese)
    }

    func testDetectEnglish() {
        XCTAssertEqual(UsageStats.detectLanguage("the quick brown fox jumps"), .english)
    }

    func testDetectNilForEmpty() {
        XCTAssertNil(UsageStats.detectLanguage(""))
        XCTAssertNil(UsageStats.detectLanguage("   \n  "))
    }

    func testDetectNilForPunctuationOnly() {
        XCTAssertNil(UsageStats.detectLanguage("!?.,;: —— 。、"))
    }

    func testMixedHanLatinFiftyFiftyIsChinese() {
        // 4 Han + 4 Latin letters, exactly 50% Han → Chinese (>= threshold)
        XCTAssertEqual(UsageStats.detectLanguage("你好世界 abcd"), .chinese)
    }

    // MARK: - Word / char counting

    func testChineseCharCountHanOnly() {
        XCTAssertEqual(UsageStats.countUnits("你好，世界！", language: .chinese), 4)
    }

    func testJapaneseCountKanaPlusHan() {
        // 3 kana (こ れ は) + ... count kana+han, exclude ascii/punct
        XCTAssertEqual(UsageStats.countUnits("これは本", language: .japanese), 4)
    }

    func testEnglishWordCountExcludesPunctuationTokens() {
        XCTAssertEqual(UsageStats.countUnits("hello , world ! foo", language: .english), 3)
    }

    // MARK: - Percentile

    func testPercentileNilBelowThreshold() {
        // Few words → below minWordsForStats(200) → nil
        let recs = [rec("hello world", duration: 5)]
        XCTAssertNil(UsageStats.computePercentile(recordings: recs, language: .english))
    }

    func testPercentileEnglishMidRange() {
        // Build enough English words at ~42 wpm (p50) → expect ~50.
        // 300 words over (300/42)*60 ≈ 428.57s
        let text = Array(repeating: "word", count: 300).joined(separator: " ")
        let recs = [rec(text, duration: 300.0 / 42.0 * 60.0)]
        let p = UsageStats.computePercentile(recordings: recs, language: .english)
        XCTAssertNotNil(p)
        XCTAssertEqual(p!, 50, accuracy: 2)
    }

    func testPercentileAboveP99ExtrapolatesIntoTail() {
        // 300 words at 200 wpm (>> p99=120) → into the 99→99.99 elite tail.
        let text = Array(repeating: "word", count: 300).joined(separator: " ")
        let recs = [rec(text, duration: 300.0 / 200.0 * 60.0)]
        let p = UsageStats.computePercentile(recordings: recs, language: .english)
        XCTAssertNotNil(p)
        XCTAssertGreaterThan(p!, 99)
        XCTAssertLessThanOrEqual(p!, 99.99)
    }

    func testPercentileNeverExceedsMax() {
        // Absurd speed must still clamp at 99.99 (Top 0.01%).
        let text = Array(repeating: "word", count: 1000).joined(separator: " ")
        let recs = [rec(text, duration: 1.0)] // 60000 wpm
        XCTAssertEqual(UsageStats.computePercentile(recordings: recs, language: .english)!, 99.99, accuracy: 0.001)
    }

    func testPercentileClampsBelowP10() {
        // 300 words at 10 wpm → below p10 → clamp to 10
        let text = Array(repeating: "word", count: 300).joined(separator: " ")
        let recs = [rec(text, duration: 300.0 / 10.0 * 60.0)]
        XCTAssertEqual(UsageStats.computePercentile(recordings: recs, language: .english)!, 10, accuracy: 0.001)
    }

    func testFormatTopTrimsDecimals() {
        XCTAssertEqual(UsageStats.formatTop(5), "5")
        XCTAssertEqual(UsageStats.formatTop(0.01), "0.01")
        XCTAssertEqual(UsageStats.formatTop(0.1), "0.1")
        XCTAssertEqual(UsageStats.formatTop(1), "1")
    }

    func testPercentileExcludesZeroDuration() {
        // A zero-duration recording must not produce NaN/Inf; valid one drives the result.
        let text = Array(repeating: "word", count: 300).joined(separator: " ")
        let recs = [
            rec(text, duration: 0),
            rec(text, duration: 300.0 / 42.0 * 60.0)
        ]
        let p = UsageStats.computePercentile(recordings: recs, language: .english)
        XCTAssertNotNil(p)
        XCTAssertEqual(p!, 50, accuracy: 3)
    }

    // MARK: - Time saved

    func testTimeSavedFlooredAtZero() {
        // Speak fast: 300 words in 60s → typing would take 300/42*60 ≈ 428s; saved ≈ 368s
        let text = Array(repeating: "word", count: 300).joined(separator: " ")
        let saved = UsageStats.timeSaved(recordings: [rec(text, duration: 60)], language: .english)
        XCTAssertGreaterThan(saved, 300)
    }

    func testTimeSavedNeverNegative() {
        // Speak very slowly: 10 words in 600s → typing faster → floor at 0
        let recs = [rec("a b c d e f g h i j", duration: 600)]
        XCTAssertEqual(UsageStats.timeSaved(recordings: recs, language: .english), 0, accuracy: 0.001)
    }

    // MARK: - Streak

    func testStreakConsecutiveDays() {
        let cal = Calendar.current
        let now = Date()
        let recs = [
            rec("hi", daysAgo: 0, calendar: cal, now: now),
            rec("hi", daysAgo: 1, calendar: cal, now: now),
            rec("hi", daysAgo: 2, calendar: cal, now: now)
        ]
        XCTAssertEqual(UsageStats.currentStreak(recordings: recs, calendar: cal, now: now), 3)
    }

    func testStreakBreaksOnGap() {
        let cal = Calendar.current
        let now = Date()
        let recs = [
            rec("hi", daysAgo: 0, calendar: cal, now: now),
            rec("hi", daysAgo: 2, calendar: cal, now: now) // gap at day 1
        ]
        XCTAssertEqual(UsageStats.currentStreak(recordings: recs, calendar: cal, now: now), 1)
    }

    func testStreakZeroWhenNoRecordingsToday() {
        XCTAssertEqual(UsageStats.currentStreak(recordings: [], calendar: .current, now: Date()), 0)
    }

    func testStreakExcludesFailed() {
        let cal = Calendar.current
        let now = Date()
        let recs = [rec("hi", daysAgo: 0, status: .failed, calendar: cal, now: now)]
        XCTAssertEqual(UsageStats.currentStreak(recordings: recs, calendar: cal, now: now), 0)
    }

    // MARK: - Busiest day

    func testBusiestDayByCount() {
        let cal = Calendar.current
        let now = Date()
        let recs = [
            rec("hi", daysAgo: 0, calendar: cal, now: now),
            rec("hi", daysAgo: 1, calendar: cal, now: now),
            rec("hi", daysAgo: 1, calendar: cal, now: now)
        ]
        let day = UsageStats.busiestDay(recordings: recs, calendar: cal)
        XCTAssertNotNil(day)
        let expected = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: now)!)
        XCTAssertEqual(cal.startOfDay(for: day!), expected)
    }

    // MARK: - Activity buckets

    func testActivityHourlyBuckets() {
        let cal = Calendar.current
        let now = Date()
        let recs = [
            rec("hi", hour: 9, calendar: cal, now: now),
            rec("hi", hour: 9, calendar: cal, now: now),
            rec("hi", hour: 20, calendar: cal, now: now)
        ]
        let buckets = UsageStats.activityByHour(recordings: recs, calendar: cal)
        XCTAssertEqual(buckets.count, 24)
        XCTAssertEqual(buckets[9], 2)
        XCTAssertEqual(buckets[20], 1)
        XCTAssertEqual(buckets[0], 0)
    }
}
