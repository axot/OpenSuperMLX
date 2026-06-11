//
//  SidebarLayoutTests.swift
//  OpenSuperMLXTests
//
//  Tests SidebarTab enum properties (icon names, labels, ordering).
//  Does NOT test SwiftUI view state or tab switching (UI behavior).
//

import XCTest
@testable import OpenSuperMLX

final class SidebarLayoutTests: XCTestCase {

    // MARK: - Ordering / allCases

    func testTabOrdering() {
        XCTAssertEqual(SidebarTab.allCases, [.recordings, .stats, .settings])
    }

    func testRawValuesAreSequential() {
        XCTAssertEqual(SidebarTab.recordings.rawValue, 0)
        XCTAssertEqual(SidebarTab.stats.rawValue, 1)
        XCTAssertEqual(SidebarTab.settings.rawValue, 2)
    }

    // MARK: - Labels

    func testLabels() {
        XCTAssertEqual(SidebarTab.recordings.label, "Recordings")
        XCTAssertEqual(SidebarTab.stats.label, "Stats")
        XCTAssertEqual(SidebarTab.settings.label, "Settings")
    }

    // MARK: - Icon names

    func testSystemImagesAreNonEmpty() {
        for tab in SidebarTab.allCases {
            XCTAssertFalse(tab.systemImage.isEmpty, "tab \(tab.label) has empty systemImage")
        }
    }

    func testSystemImagesAreDistinct() {
        let names = SidebarTab.allCases.map(\.systemImage)
        XCTAssertEqual(Set(names).count, names.count, "sidebar icon names must be unique")
    }

    // MARK: - Identifiable

    func testIDMatchesRawValue() {
        for tab in SidebarTab.allCases {
            XCTAssertEqual(tab.id, tab.rawValue)
        }
    }
}
