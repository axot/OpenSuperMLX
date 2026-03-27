//
//  FillerWordPromptTests.swift
//  OpenSuperMLXTests
//

import XCTest
@testable import MLXAudioSTT

final class FillerWordPromptTests: XCTestCase {

    // MARK: - StreamingConfig Defaults

    func testStreamingConfigDefaultsUnchanged() throws {
        let config = StreamingConfig()
        XCTAssertEqual(config.language, "English")
        XCTAssertEqual(config.temperature, 0.0)
    }
}
