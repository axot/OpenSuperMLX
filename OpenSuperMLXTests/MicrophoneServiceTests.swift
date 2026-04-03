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
    
    func testBluetoothDetection_MACAddressAloneIsInsufficient() {
        let device = MicrophoneService.AudioDevice(
            id: "AA-BB-CC-DD-EE-FF:input",
            name: "Wireless Headset",
            manufacturer: "Acme",
            isBuiltIn: false
        )
        // MAC address format triggers CoreAudio transport type check;
        // fake device has no CoreAudio entry, so detection returns false
        XCTAssertFalse(MicrophoneService.shared.isBluetoothMicrophone(device))
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

// MARK: - Virtual Device Detection

final class MicrophoneServiceVirtualDeviceTests: XCTestCase {

    func testVirtualDetection_BlackHole2ch() {
        let device = MicrophoneService.AudioDevice(id: "BlackHole2ch_UID", name: "BlackHole 2ch", manufacturer: "Existential Audio Inc.", isBuiltIn: false)
        XCTAssertTrue(MicrophoneService.shared.isVirtualDevice(device))
    }

    func testVirtualDetection_BlackHole16ch() {
        let device = MicrophoneService.AudioDevice(id: "BlackHole16ch_UID", name: "BlackHole 16ch", manufacturer: "Existential Audio Inc.", isBuiltIn: false)
        XCTAssertTrue(MicrophoneService.shared.isVirtualDevice(device))
    }

    func testVirtualDetection_Soundflower() {
        let device = MicrophoneService.AudioDevice(id: "SoundflowerEngine:0", name: "Soundflower (2ch)", manufacturer: "Cycling '74", isBuiltIn: false)
        XCTAssertTrue(MicrophoneService.shared.isVirtualDevice(device))
    }

    func testVirtualDetection_LoopbackInName() {
        let device = MicrophoneService.AudioDevice(id: "com.rogueamoeba.loopback", name: "Loopback Audio", manufacturer: "Rogue Amoeba", isBuiltIn: false)
        XCTAssertTrue(MicrophoneService.shared.isVirtualDevice(device))
    }

    func testVirtualDetection_AggregateDevice() {
        let device = MicrophoneService.AudioDevice(id: "aggregate-123", name: "Aggregate Device", manufacturer: nil, isBuiltIn: false)
        XCTAssertTrue(MicrophoneService.shared.isVirtualDevice(device))
    }

    func testVirtualDetection_MultiOutputDevice() {
        let device = MicrophoneService.AudioDevice(id: "multi-output-123", name: "Multi-Output Device", manufacturer: nil, isBuiltIn: false)
        XCTAssertTrue(MicrophoneService.shared.isVirtualDevice(device))
    }

    func testVirtualDetection_BuiltInMicIsNotVirtual() {
        let device = MicrophoneService.AudioDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", manufacturer: "Apple Inc.", isBuiltIn: true)
        XCTAssertFalse(MicrophoneService.shared.isVirtualDevice(device))
    }

    func testVirtualDetection_USBMicIsNotVirtual() {
        let device = MicrophoneService.AudioDevice(id: "usb-audio-device-123", name: "Blue Yeti", manufacturer: "Blue Microphones", isBuiltIn: false)
        XCTAssertFalse(MicrophoneService.shared.isVirtualDevice(device))
    }
}

// MARK: - Requires Connection

final class MicrophoneServiceRequiresConnectionTests: XCTestCase {
    
    func testRequiresConnection_iPhone() {
        let device = MicrophoneService.AudioDevice(
            id: "DEADBEEF-1234-5678-ABCD-000000000001",
            name: "iPhone Microphone",
            manufacturer: "Apple Inc.",
            isBuiltIn: false
        )
        XCTAssertTrue(MicrophoneService.shared.isContinuityMicrophone(device))
        XCTAssertTrue(MicrophoneService.shared.isBluetoothMicrophone(device) || MicrophoneService.shared.isContinuityMicrophone(device))
    }
    
    func testRequiresConnection_MACAddressWithoutCoreAudio() {
        let device = MicrophoneService.AudioDevice(
            id: "AA-BB-CC-DD-EE-FF:input",
            name: "Wireless Headset",
            manufacturer: "Acme",
            isBuiltIn: false
        )
        XCTAssertFalse(MicrophoneService.shared.isBluetoothMicrophone(device))
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
