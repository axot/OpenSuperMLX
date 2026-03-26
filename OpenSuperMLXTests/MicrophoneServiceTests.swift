// MicrophoneServiceTests.swift
// OpenSuperMLX

import AVFoundation
import XCTest

@testable import OpenSuperMLX

final class MicrophoneInventoryTests: XCTestCase {
    
    func testPrintConnectedMicrophones() throws {
        let service = MicrophoneService.shared
        service.refreshAvailableMicrophones()
        let available = service.availableMicrophones
        for device in available {
            _ = device.name
            _ = device.id
            _ = device.manufacturer
            _ = device.isBuiltIn
            _ = service.isContinuityMicrophone(device)
            _ = service.isBluetoothMicrophone(device)
        }
        
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.microphone, .external, .builtInMicrophone]
        }
        
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        
        for device in discoverySession.devices {
            _ = device.localizedName
            _ = device.uniqueID
            _ = device.manufacturer
            _ = device.deviceType.rawValue
            _ = device.transportType
        }
    }
}

// MARK: - Continuity Detection

final class MicrophoneServiceContinuityTests: XCTestCase {
    
    func testContinuityDetection_iPhoneApple() {
        let device = MicrophoneService.AudioDevice(
            id: "com.apple.continuity.iphone",
            name: "iPhone Microphone",
            manufacturer: "Apple",
            isBuiltIn: false
        )
        XCTAssertTrue(MicrophoneService.shared.isContinuityMicrophone(device))
    }
    
    func testContinuityDetection_ContinuityApple() {
        let device = MicrophoneService.AudioDevice(
            id: "com.apple.continuity.mic",
            name: "Continuity Microphone",
            manufacturer: "Apple",
            isBuiltIn: false
        )
        XCTAssertTrue(MicrophoneService.shared.isContinuityMicrophone(device))
    }
    
    func testContinuityDetection_NotApple() {
        let device = MicrophoneService.AudioDevice(
            id: "com.vendor.iphone",
            name: "iPhone Microphone",
            manufacturer: "Vendor",
            isBuiltIn: false
        )
        XCTAssertFalse(MicrophoneService.shared.isContinuityMicrophone(device))
    }
    
    func testContinuityDetection_AppleBuiltIn() {
        let device = MicrophoneService.AudioDevice(
            id: "builtin",
            name: "MacBook Pro Microphone",
            manufacturer: "Apple",
            isBuiltIn: true
        )
        XCTAssertFalse(MicrophoneService.shared.isContinuityMicrophone(device))
    }
}

// MARK: - Bluetooth Detection

final class MicrophoneServiceBluetoothTests: XCTestCase {
    
    func testBluetoothDetection_BluetoothInName() {
        let device = MicrophoneService.AudioDevice(
            id: "some-id",
            name: "Bluetooth Headphones",
            manufacturer: "Apple",
            isBuiltIn: false
        )
        XCTAssertTrue(MicrophoneService.shared.isBluetoothMicrophone(device))
    }
    
    func testBluetoothDetection_BluetoothInID() {
        let device = MicrophoneService.AudioDevice(
            id: "bluetooth-device-123",
            name: "Headphones",
            manufacturer: "Apple",
            isBuiltIn: false
        )
        XCTAssertTrue(MicrophoneService.shared.isBluetoothMicrophone(device))
    }
    
    func testBluetoothDetection_MACAddress() {
        let device = MicrophoneService.AudioDevice(
            id: "00-22-BB-71-21-0A:input",
            name: "Amiron wireless",
            manufacturer: "Apple",
            isBuiltIn: false
        )
        XCTAssertTrue(MicrophoneService.shared.isBluetoothMicrophone(device))
    }
    
    func testBluetoothDetection_NotBluetooth() {
        let device = MicrophoneService.AudioDevice(
            id: "builtin",
            name: "MacBook Pro Microphone",
            manufacturer: "Apple",
            isBuiltIn: true
        )
        XCTAssertFalse(MicrophoneService.shared.isBluetoothMicrophone(device))
    }
}

// MARK: - Requires Connection

final class MicrophoneServiceRequiresConnectionTests: XCTestCase {
    
    func testRequiresConnection_iPhone() {
        let device = MicrophoneService.AudioDevice(
            id: "B95EA61C-AC67-43B3-8AB4-8AE800000003",
            name: "Микрофон (iPhone nagibator)",
            manufacturer: "Apple Inc.",
            isBuiltIn: false
        )
        XCTAssertTrue(MicrophoneService.shared.isContinuityMicrophone(device))
        XCTAssertTrue(MicrophoneService.shared.isBluetoothMicrophone(device) || MicrophoneService.shared.isContinuityMicrophone(device))
    }
    
    func testRequiresConnection_Bluetooth() {
        let device = MicrophoneService.AudioDevice(
            id: "00-22-BB-71-21-0A:input",
            name: "Amiron wireless",
            manufacturer: "Apple",
            isBuiltIn: false
        )
        XCTAssertTrue(MicrophoneService.shared.isBluetoothMicrophone(device))
    }
    
    func testRequiresConnection_BuiltIn() {
        let device = MicrophoneService.AudioDevice(
            id: "BuiltInMicrophoneDevice",
            name: "Микрофон MacBook Pro",
            manufacturer: "Apple Inc.",
            isBuiltIn: true
        )
        XCTAssertFalse(MicrophoneService.shared.isContinuityMicrophone(device))
        XCTAssertFalse(MicrophoneService.shared.isBluetoothMicrophone(device))
    }
}
