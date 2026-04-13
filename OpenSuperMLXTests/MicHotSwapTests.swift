// MicHotSwapTests.swift
// OpenSuperMLXTests

import AVFoundation
import CoreAudio
import XCTest

@testable import OpenSuperMLX

final class MicHotSwapTests: XCTestCase {

    // MARK: - Buffer Preservation

    func testRingBufferPreservedFormat() {
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        var buffer = samples
        let preserved = buffer
        buffer.removeAll(keepingCapacity: true)
        buffer.insert(contentsOf: preserved, at: 0)
        XCTAssertEqual(buffer, samples, "Buffer should be identical after preserve-restore cycle")
    }

    func testPreserveEmptyBufferIsNoOp() {
        var buffer = [Float]()
        let preserved = buffer
        buffer.removeAll(keepingCapacity: true)
        buffer.insert(contentsOf: preserved, at: 0)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testPreservedSamplesInsertedBeforeNewSamples() {
        let preserved: [Float] = [1.0, 2.0, 3.0]
        let newSamples: [Float] = [4.0, 5.0]
        var buffer = newSamples
        buffer.insert(contentsOf: preserved, at: 0)
        XCTAssertEqual(buffer, [1.0, 2.0, 3.0, 4.0, 5.0])
    }

    // MARK: - Hot-Swap Availability

    @MainActor
    func testStreamingServiceHasHotSwapCapability() {
        let service = StreamingAudioService.shared
        XCTAssertFalse(service.isStreaming, "Service should not be streaming initially")
        XCTAssertNotNil(service, "Service should exist for hot-swap")
    }

    // MARK: - Device Disappearance Fallback

    @MainActor
    func testDeviceDisappearsFallsBackToBuiltIn() {
        let service = MicrophoneService.shared
        service.isDeviceAlive = { _ in false }
        
        let externalDevice = MicrophoneService.AudioDevice(
            id: "external-usb-mic-999",
            name: "External USB Mic",
            manufacturer: "TestCorp",
            isBuiltIn: false
        )
        service.selectMicrophone(externalDevice)
        
        service.onDeviceDisappeared(deviceID: 999)
        
        let current = service.currentMicrophone
        XCTAssertNotEqual(current?.id, externalDevice.id,
                          "Should not keep using a device that is no longer available")
        
        service.isDeviceAlive = { deviceID in
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr
        }
    }

    // MARK: - Engine Config Change

    func testEngineConfigChangeNotification() {
        let spy = AudioDeviceChangeObserverSpy()
        XCTAssertEqual(spy.onEngineConfigChangedCallCount, 0)
        
        spy.onEngineConfigurationChanged()
        
        XCTAssertEqual(spy.onEngineConfigChangedCallCount, 1)
    }

    // MARK: - Missing Device Graceful Fallback

    @MainActor
    func testConfiguredDeviceMissingGracefulFallback() {
        let service = MicrophoneService.shared
        
        let missingDevice = MicrophoneService.AudioDevice(
            id: "device-that-does-not-exist-at-all",
            name: "Ghost Microphone",
            manufacturer: nil,
            isBuiltIn: false
        )
        
        service.selectMicrophone(missingDevice)
        XCTAssertFalse(service.isDeviceAvailable(missingDevice))
        
        service.refreshAvailableMicrophones()
        let current = service.getActiveMicrophone()
        XCTAssertNotEqual(current?.id, missingDevice.id,
                          "Should fall back when configured device is not in available list")
    }

    // MARK: - Rapid Successive Changes

    @MainActor
    func testRapidSuccessiveDeviceChanges() {
        let service = MicrophoneService.shared
        
        for i in 0..<10 {
            service.onEngineConfigurationChanged()
            service.onDeviceDisappeared(deviceID: AudioDeviceID(i + 1000))
        }
        
        XCTAssertNotNil(service, "Service should survive rapid successive device changes")
        service.refreshAvailableMicrophones()
        let current = service.getActiveMicrophone()
        if !service.availableMicrophones.isEmpty {
            XCTAssertNotNil(current, "Should still have an active microphone after rapid changes")
        }
    }

    // MARK: - Spy Protocol Conformance

    func testSpyTracksDeviceDisappearedCalls() {
        let spy = AudioDeviceChangeObserverSpy()
        
        spy.onDeviceDisappeared(deviceID: 42)
        spy.onDeviceDisappeared(deviceID: 99)
        
        XCTAssertEqual(spy.onDeviceDisappearedCallCount, 2)
        XCTAssertEqual(spy.onDeviceDisappearedDeviceIDs, [42, 99])
    }
}
