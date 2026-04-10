// QueueCommandTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

@MainActor
final class QueueCommandTests: XCTestCase {

    // MARK: - Add

    func testQueueAddNonExistentFile() async throws {
        let result = QueueAddCommand.executeAdd(files: ["/nonexistent/path/audio.wav"])
        guard case .failure(let error) = result else {
            XCTFail("Expected failure"); return
        }
        XCTAssertEqual(error, .audioFileNotFound)
    }

    func testQueueAddValidatesAllFiles() async throws {
        let result = QueueAddCommand.executeAdd(files: ["/tmp/a.wav", "/nonexistent/b.wav"])
        guard case .failure(let error) = result else {
            XCTFail("Expected failure"); return
        }
        XCTAssertEqual(error, .audioFileNotFound)
    }

    // MARK: - Status

    func testQueueStatusOutput() async throws {
        let result = await QueueStatusCommand.executeStatus()
        guard case .success(let status) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertGreaterThanOrEqual(status.pending, 0)
        XCTAssertGreaterThanOrEqual(status.completed, 0)
        XCTAssertNotNil(status.isProcessing)
    }
}
