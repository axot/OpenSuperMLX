// MicrophoneServiceAutoModeTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class MicrophoneServiceAutoModeTests: XCTestCase {

    // MARK: - AudioSourceMode

    func testAudioSourceModeRawValues() {
        XCTAssertEqual(AudioSourceMode.auto.rawValue, "auto")
        XCTAssertEqual(AudioSourceMode.microphoneOnly.rawValue, "microphoneOnly")
    }

    func testAudioSourceModeDecodable() throws {
        let json = Data(#""auto""#.utf8)
        let decoded = try JSONDecoder().decode(AudioSourceMode.self, from: json)
        XCTAssertEqual(decoded, .auto)
    }

    // MARK: - ResolvedAudioSource

    func testResolvedAudioSourceConstruction() {
        let resolved = ResolvedAudioSource(
            mode: .dualTrack,
            outputType: .headphones,
            callingApp: "Zoom",
            bundleID: "us.zoom.xos"
        )
        XCTAssertEqual(resolved.mode, .dualTrack)
        XCTAssertEqual(resolved.outputType, .headphones)
        XCTAssertEqual(resolved.callingApp, "Zoom")
        XCTAssertEqual(resolved.bundleID, "us.zoom.xos")
    }

    func testResolvedAudioSourceMicOnlyWithNilCallingApp() {
        let resolved = ResolvedAudioSource(
            mode: .micOnly,
            outputType: .speakers,
            callingApp: nil,
            bundleID: nil
        )
        XCTAssertEqual(resolved.mode, .micOnly)
        XCTAssertNil(resolved.callingApp)
        XCTAssertNil(resolved.bundleID)
    }

    // MARK: - Default Mode

    func testDefaultAudioSourceModeIsAuto() {
        let service = MicrophoneService.shared
        XCTAssertEqual(service.audioSourceMode, .auto)
    }

    // MARK: - resolveAudioSource

    func testResolveAudioSourceMicrophoneOnlyReturnsMicOnly() {
        let service = MicrophoneService.shared
        service.audioSourceMode = .microphoneOnly
        defer { service.audioSourceMode = .auto }

        let resolved = service.resolveAudioSource()
        XCTAssertEqual(resolved.mode, .micOnly)
        XCTAssertNil(resolved.callingApp)
        XCTAssertNil(resolved.bundleID)
    }
}
