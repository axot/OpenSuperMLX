// StreamingTypesTests.swift
// OpenSuperMLXTests

import XCTest

@testable import MLXAudioSTT

final class StreamingTypesTests: XCTestCase {
    func testGapEncodingReportsRecordingSecondsAndReason() throws {
        let gap = StreamingTranscriptionGap(
            startSeconds: 1014.2, endSeconds: 1022.2,
            reason: "token_limit generated_tokens=256 eos=false"
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(gap)) as? [String: Any]
        )
        XCTAssertEqual(json["start_seconds"] as? Double, 1014.2)
        XCTAssertEqual(json["end_seconds"] as? Double, 1022.2)
        XCTAssertEqual(json["reason"] as? String, gap.reason)
    }

    func testGapTimeRangeUsesRecordingMinutesAndTenths() {
        let gap = StreamingTranscriptionGap(startSeconds: 1014.2, endSeconds: 1022.2, reason: "test")
        XCTAssertEqual(gap.timeRange, "16:54.2–17:02.2")
    }

    func testGapTimeRangeCarriesRoundingIntoMinutes() {
        let gap = StreamingTranscriptionGap(startSeconds: 59.96, endSeconds: 3600, reason: "test")
        XCTAssertEqual(gap.timeRange, "01:00.0–60:00.0")
    }
}
