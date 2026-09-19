// MicDeviceBindingProbeTests.swift
// OpenSuperMLXTests

import AVFoundation
import CoreAudio
import XCTest
import os

@testable import OpenSuperMLX

/// Live-hardware validation of the pinned-device engine-init transaction. Skips unless
/// the machine exposes at least two input-capable devices, so CI (no audio hardware)
/// never runs it. Exercises the same bind → start → verify primitives as production.
final class MicDeviceBindingProbeTests: XCTestCase {

    private func inputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        let streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        return ids.filter { id in
            var streamSize: UInt32 = 0
            var addr = streamsAddress
            return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &streamSize) == noErr
                && streamSize > 0
        }
    }

    private func deviceUID(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid)
        guard status == noErr, let cf = uid?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private func requireSecondInputDevice() throws -> AudioDeviceID {
        let inputs = inputDeviceIDs()
        guard inputs.count >= 2 else {
            throw XCTSkip("Requires at least two input devices to exercise a non-default binding")
        }
        guard let defaultID = defaultInputDeviceID(),
              let other = inputs.first(where: { $0 != defaultID }) else {
            throw XCTSkip("No non-default input device available")
        }
        return other
    }

    func testNonDefaultDeviceBindingSurvivesStartAndEvaluatesCommit() async throws {
        let target = try requireSecondInputDevice()

        // Let any prior process's released input AU fully drain from the HAL before
        // binding — back-to-back test runs otherwise contend for the device.
        try await Task.sleep(for: .seconds(1))

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        var deviceID = target
        let bindStatus = AudioUnitSetProperty(
            inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        XCTAssertEqual(bindStatus, noErr, "binding the non-default device must succeed")

        do {
            try engine.start()
        } catch {
            engine.stop()
            throw XCTSkip("engine.start unavailable on this machine: \(error)")
        }
        defer { engine.stop() }

        let bound = StreamingAudioService.boundInputDeviceID(of: engine)
        XCTAssertEqual(bound, target, "the binding must survive engine.start()")

        let inputFormat = inputNode.inputFormat(forBus: 0)
        let observation = EngineInitObservation(
            engineRunning: engine.isRunning,
            startErrorDescription: nil,
            boundDeviceID: bound,
            targetDeviceID: target,
            deviceSideFormat: EngineInitFormat(
                sampleRate: inputFormat.sampleRate,
                channelCount: Int(inputFormat.channelCount),
                isInterleaved: inputFormat.isInterleaved
            )
        )
        guard case .commit = EngineInitTransaction.evaluate(observation) else {
            return XCTFail("verified post-start state must commit, got \(EngineInitTransaction.evaluate(observation))")
        }

        // The crash-critical ordering: the tap is installed only AFTER verification
        // passed, on a running engine still bound to the target. installTap raises an
        // Objective-C exception on a mismatched format — surviving this call is the point.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { _, _ in }
        inputNode.removeTap(onBus: 0)
        XCTAssertEqual(StreamingAudioService.boundInputDeviceID(of: engine), target, "tap install must not disturb the binding")
        XCTAssertTrue(engine.isRunning)
    }
}
