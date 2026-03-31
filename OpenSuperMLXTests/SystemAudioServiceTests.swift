// SystemAudioServiceTests.swift
// OpenSuperMLX

import ScreenCaptureKit
import XCTest

@testable import OpenSuperMLX

final class SystemAudioServiceTests: XCTestCase {

    // MARK: - SCStreamConfiguration

    func testStreamConfigurationAudioProperties() throws {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1

        XCTAssertTrue(config.capturesAudio)
        XCTAssertTrue(config.excludesCurrentProcessAudio)
        XCTAssertEqual(config.sampleRate, 16000)
        XCTAssertEqual(config.channelCount, 1)
    }

    func testStreamConfigurationMinimizesVideoOverhead() throws {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        XCTAssertEqual(config.width, 2)
        XCTAssertEqual(config.height, 2)
        XCTAssertEqual(config.minimumFrameInterval, CMTime(value: 1, timescale: 1))
    }

    // MARK: - SCContentFilter

    func testContentFilterCreationForDisplay() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            throw XCTSkip("Screen Recording permission not granted: \(error.localizedDescription)")
        }

        guard let display = content.displays.first else {
            throw XCTSkip("No display available")
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        XCTAssertNotNil(filter)
    }

    // MARK: - SystemAudioService

    @MainActor
    func testServiceIsSingleton() throws {
        let a = SystemAudioService.shared
        let b = SystemAudioService.shared
        XCTAssertTrue(a === b)
    }

    @MainActor
    func testSystemAudioServiceConfiguration() throws {
        let service = SystemAudioService.shared
        let config = service.makeStreamConfiguration()

        XCTAssertTrue(config.capturesAudio)
        XCTAssertTrue(config.excludesCurrentProcessAudio)
        XCTAssertEqual(config.sampleRate, 16000)
        XCTAssertEqual(config.channelCount, 1)
    }

    @MainActor
    func testSystemAudioServiceInitialState() throws {
        let service = SystemAudioService.shared
        XCTAssertFalse(service.isCapturing)
    }

    @MainActor
    func testStopCaptureReturnsNilWhenNotCapturing() async throws {
        let service = SystemAudioService.shared
        let url = await service.stopCapture()
        XCTAssertNil(url)
    }

    @MainActor
    func testConvertSampleBufferToFloatsWithNilReturnsEmpty() throws {
        let service = SystemAudioService.shared
        let result = service.extractFloatSamples(from: nil)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Per-App Filter

    @MainActor
    func testMakeContentFilterThrowsForUnknownBundleID() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            throw XCTSkip("Screen Recording permission not granted: \(error.localizedDescription)")
        }

        guard content.displays.first != nil else {
            throw XCTSkip("No display available")
        }

        let service = SystemAudioService.shared
        do {
            _ = try service.makeContentFilter(
                bundleID: "com.nonexistent.fake.app.12345", content: content
            )
            XCTFail("Expected applicationNotFound error")
        } catch let error as SystemAudioCaptureError {
            if case .applicationNotFound(let id) = error {
                XCTAssertEqual(id, "com.nonexistent.fake.app.12345")
            } else {
                XCTFail("Expected applicationNotFound, got \(error)")
            }
        }
    }
}
