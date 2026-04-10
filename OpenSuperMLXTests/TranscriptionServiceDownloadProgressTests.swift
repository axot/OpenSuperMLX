// TranscriptionServiceDownloadProgressTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

@MainActor
final class TranscriptionServiceDownloadProgressTests: XCTestCase {

    // MARK: - Initial State

    func testDownloadProgressIsNilByDefault() {
        let service = TranscriptionService(engine: nil)
        XCTAssertNil(service.downloadProgress)
    }

    func testDownloadProgressIsOptionalDouble() {
        let service = TranscriptionService(engine: nil)
        let progress: Double? = service.downloadProgress
        XCTAssertNil(progress)
    }

    func testDownloadProgressDoesNotConflictWithTranscriptionProgress() {
        let service = TranscriptionService(engine: nil)
        XCTAssertEqual(service.progress, 0.0)
        XCTAssertNil(service.downloadProgress)
    }
}
