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

    // MARK: - Updates

    func testDownloadProgressNeverMovesBackWithinOneDownload() {
        let service = TranscriptionService(engine: nil)
        let download = Progress(totalUnitCount: 100)

        download.completedUnitCount = 60
        service.updateDownloadProgress(download)
        download.completedUnitCount = 20
        service.updateDownloadProgress(download)

        XCTAssertEqual(service.downloadProgress, 0.6)
    }

    func testNextDownloadRestartsProgress() {
        let service = TranscriptionService(engine: nil)
        let encoderDownload = Progress(totalUnitCount: 100)
        encoderDownload.completedUnitCount = 100
        service.updateDownloadProgress(encoderDownload)

        let modelDownload = Progress(totalUnitCount: 100)
        modelDownload.completedUnitCount = 30
        service.updateDownloadProgress(modelDownload)

        XCTAssertEqual(service.downloadProgress, 0.3)
    }
}
