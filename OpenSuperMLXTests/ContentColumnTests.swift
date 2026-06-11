//
//  ContentColumnTests.swift
//  OpenSuperMLXTests
//
//  Tests ContentColumnLayout.columnWidth — the width-cap math that replaced the
//  `.frame(maxWidth: cap).frame(maxWidth: .infinity)` idiom. The idiom laid
//  content out at the full cap inside a width-greedy ScrollView, so at windows
//  narrower than the cap the content overflowed the region and was clipped on the
//  right. The invariant under test: the column is never wider than the region.
//

import XCTest
@testable import OpenSuperMLX

final class ContentColumnTests: XCTestCase {

    // MARK: - Regression: column never exceeds the region (the clipping bug)

    func testColumnNeverExceedsRegionWhenRegionBelowCap() {
        // Region = window(760) - sidebar(240) = 520, well below the 880 cap.
        // The old idiom produced 880 here; the surplus (360pt) clipped on the right.
        let w = ContentColumnLayout.columnWidth(region: 520, cap: 880)
        XCTAssertEqual(w, 520, "column must shrink to the region, not stay at the cap")
        XCTAssertLessThanOrEqual(w, 520, "column must never exceed the available region")
    }

    func testColumnNeverExceedsRegionAcrossResizeRange() {
        // Every window width in the valid 750–1100 range (region = width − 240).
        for window in stride(from: 750.0, through: 1100.0, by: 5.0) {
            let region = window - 240
            let w = ContentColumnLayout.columnWidth(region: region, cap: 880)
            XCTAssertLessThanOrEqual(w, region, "overflow at window=\(window) (region=\(region))")
        }
    }

    // MARK: - Capping behavior

    func testColumnCapsAtMaxWhenRegionExceedsCap() {
        // Region wider than the cap → column clamps to the cap and centers.
        let w = ContentColumnLayout.columnWidth(region: 1200, cap: 880)
        XCTAssertEqual(w, 880)
    }

    func testColumnEqualsRegionAtCapBoundary() {
        let w = ContentColumnLayout.columnWidth(region: 880, cap: 880)
        XCTAssertEqual(w, 880)
    }

    // MARK: - Edge cases

    func testZeroRegionYieldsZero() {
        XCTAssertEqual(ContentColumnLayout.columnWidth(region: 0, cap: 880), 0)
    }

    func testNegativeRegionClampsToZero() {
        // A transient negative offered width during layout must not produce a
        // negative frame width.
        XCTAssertEqual(ContentColumnLayout.columnWidth(region: -50, cap: 880), 0)
    }
}
