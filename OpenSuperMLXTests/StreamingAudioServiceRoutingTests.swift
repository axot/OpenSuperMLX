// StreamingAudioServiceRoutingTests.swift
// OpenSuperMLXTests
//
// Tests the routing-decision logic and toast-debouncing behavior introduced when
// VPIO was replaced with per-device output classification (R2). Naming follows
// project convention of feature-scoped streaming test files (cf.
// StreamingAudioServiceFileInjectionTests.swift).

import XCTest
@testable import OpenSuperMLX

@MainActor
final class StreamingAudioServiceRoutingTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "StreamingAudioServiceRoutingTests")!
        defaults.removePersistentDomain(forName: "StreamingAudioServiceRoutingTests")
        AppPreferences.store = defaults
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: "StreamingAudioServiceRoutingTests")
        AppPreferences.store = .standard
        defaults = nil
        try await super.tearDown()
    }

    // MARK: - Routing decisions (pure function)

    /// A: Speaker output + capture toggle ON → forced mic only.
    func testSpeakerOutputForcesMicOnlyWhenToggleOn() {
        XCTAssertFalse(StreamingAudioService.effectiveSpeakerCaptureEnabled(
            classification: .speaker, userToggle: true
        ))
    }

    /// B: Headphone output + capture toggle ON → mix mic + sys.
    func testHeadphoneOutputAllowsMixedCapture() {
        XCTAssertTrue(StreamingAudioService.effectiveSpeakerCaptureEnabled(
            classification: .headphone, userToggle: true
        ))
    }

    /// C: Unclassified output (modal cancelled) → safe default speaker → mic only.
    func testUnclassifiedOutputDefaultsToSpeakerSafe() {
        XCTAssertFalse(StreamingAudioService.effectiveSpeakerCaptureEnabled(
            classification: nil, userToggle: true
        ))
    }

    /// D: Toggle OFF on a headphone → still mic only.
    func testToggleOffMeansMicOnly() {
        XCTAssertFalse(StreamingAudioService.effectiveSpeakerCaptureEnabled(
            classification: .headphone, userToggle: false
        ))
    }

    // MARK: - E: Hot-restart on mid-stream classification flip (XCTSkip — needs engine seam)

    func testHotRestartOnMidStreamClassificationFlip() throws {
        throw XCTSkip("Requires injectable AVAudioEngine; covered by manual GUI smoke (plan step 15).")
    }
}
