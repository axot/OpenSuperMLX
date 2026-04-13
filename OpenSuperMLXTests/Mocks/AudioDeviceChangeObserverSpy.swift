// AudioDeviceChangeObserverSpy.swift
// OpenSuperMLXTests

import CoreAudio

@testable import OpenSuperMLX

final class AudioDeviceChangeObserverSpy: AudioDeviceChangeObserver, @unchecked Sendable {
    var onDeviceDisappearedCallCount = 0
    var onDeviceDisappearedDeviceIDs: [AudioDeviceID] = []
    var onEngineConfigChangedCallCount = 0
    
    func onDeviceDisappeared(deviceID: AudioDeviceID) {
        onDeviceDisappearedCallCount += 1
        onDeviceDisappearedDeviceIDs.append(deviceID)
    }
    
    func onEngineConfigurationChanged() {
        onEngineConfigChangedCallCount += 1
    }
}
