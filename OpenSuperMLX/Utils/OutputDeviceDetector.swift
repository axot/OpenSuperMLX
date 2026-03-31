// OutputDeviceDetector.swift
// OpenSuperMLX

import CoreAudio
import OSLog

enum OutputType {
    case headphones
    case speakers
    case unknown
}

enum OutputDeviceDetector {

    private static let logger = Logger(subsystem: "OpenSuperMLX", category: "OutputDeviceDetector")

    // MARK: - Public API

    static func detectOutputType() -> OutputType {
        guard let deviceID = defaultOutputDeviceID() else {
            logger.error("Failed to get default output device ID")
            return .unknown
        }

        let transportType = transportType(for: deviceID)
        let dataSource: UInt32? = transportType == kAudioDeviceTransportTypeBuiltIn
            ? self.dataSource(for: deviceID)
            : nil

        return mapTransportType(transportType, dataSource: dataSource)
    }

    static func mapTransportType(_ transportType: UInt32, dataSource: UInt32?) -> OutputType {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .headphones
        case kAudioDeviceTransportTypeUSB:
            return .headphones
        case kAudioDeviceTransportTypeBuiltIn:
            return mapBuiltInDataSource(dataSource)
        default:
            return .unknown
        }
    }

    // MARK: - Private Helpers

    private static func mapBuiltInDataSource(_ dataSource: UInt32?) -> OutputType {
        guard let dataSource else { return .unknown }
        let hdpn: UInt32 = 1751412846  // "hdpn"
        let ispk: UInt32 = 1769173099  // "ispk"
        switch dataSource {
        case hdpn: return .headphones
        case ispk: return .speakers
        default: return .unknown
        }
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        guard status == noErr else {
            logger.error("AudioObjectGetPropertyData defaultOutputDevice failed: \(status)")
            return nil
        }
        return deviceID
    }

    private static func transportType(for deviceID: AudioDeviceID) -> UInt32 {
        var transportType: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(deviceID),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &transportType
        )
        if status != noErr {
            logger.error("AudioObjectGetPropertyData transportType failed: \(status)")
        }
        return transportType
    }

    private static func dataSource(for deviceID: AudioDeviceID) -> UInt32? {
        var dataSource: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(deviceID),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &dataSource
        )
        guard status == noErr else {
            logger.error("AudioObjectGetPropertyData dataSource failed: \(status)")
            return nil
        }
        return dataSource
    }
}
