//
//  OpenSuperMLXTests.swift
//  OpenSuperMLXTests
//
//  Created by user on 05.02.2025.
//

import XCTest
import Carbon
import ApplicationServices
import AVFoundation
@testable import OpenSuperMLX

final class OpenSuperMLXTests: XCTestCase {

    override func setUpWithError() throws {
    }

    override func tearDownWithError() throws {
    }

    func testPerformanceExample() throws {
        self.measure {
        }
    }
}

final class MicrophoneInventoryTests: XCTestCase {
    
    func testPrintConnectedMicrophones() throws {
        let service = MicrophoneService.shared
        service.refreshAvailableMicrophones()
        let available = service.availableMicrophones
        print("Available microphones count: \(available.count)")
        for device in available {
            print("Microphone:")
            print("  name: \(device.name)")
            print("  id: \(device.id)")
            print("  manufacturer: \(device.manufacturer ?? "nil")")
            print("  isBuiltIn: \(device.isBuiltIn)")
            print("  isContinuity: \(service.isContinuityMicrophone(device))")
            print("  isBluetooth: \(service.isBluetoothMicrophone(device))")
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
        
        print("AVCaptureDevice count: \(discoverySession.devices.count)")
        for device in discoverySession.devices {
            print("AVCaptureDevice:")
            print("  localizedName: \(device.localizedName)")
            print("  uniqueID: \(device.uniqueID)")
            print("  manufacturer: \(device.manufacturer)")
            print("  deviceType: \(device.deviceType.rawValue)")
            if #available(macOS 13.0, *) {
                print("  isConnected: \(device.isConnected)")
            }
            print("  transportType: \(device.transportType)")
        }
    }
}

// MARK: - Keyboard Layout Tests

final class ClipboardUtilKeyboardLayoutTests: XCTestCase {
    
    private var originalInputSourceID: String?
    
    override func setUpWithError() throws {
        originalInputSourceID = ClipboardUtil.getCurrentInputSourceID()
    }
    
    override func tearDownWithError() throws {
        if let originalID = originalInputSourceID {
            _ = ClipboardUtil.switchToInputSource(withID: originalID)
        }
    }
    
    func testGetAvailableInputSources() throws {
        let sources = ClipboardUtil.getAvailableInputSources()
        XCTAssertFalse(sources.isEmpty, "Should have at least one input source")
        print("Available input sources: \(sources)")
    }
    
    func testGetCurrentInputSourceID() throws {
        let currentID = ClipboardUtil.getCurrentInputSourceID()
        XCTAssertNotNil(currentID, "Should be able to get current input source ID")
        print("Current input source: \(currentID ?? "nil")")
    }
    
    func testFindKeycodeForV_USLayout() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "US")
        if !switched {
            throw XCTSkip("US layout not available")
        }
        
        let keycode = ClipboardUtil.findKeycodeForCharacter("v")
        XCTAssertNotNil(keycode, "Should find keycode for 'v' in US layout")
        XCTAssertEqual(keycode, 9, "Keycode for 'v' in US QWERTY should be 9")
    }
    
    func testFindKeycodeForV_DvorakQwertyLayout() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "DVORAK-QWERTYCMD")
        if !switched {
            throw XCTSkip("Dvorak-QWERTY layout not available")
        }
        
        let keycode = ClipboardUtil.findKeycodeForCharacter("v")
        XCTAssertNotNil(keycode, "Should find keycode for 'v' in Dvorak-QWERTY layout")
        print("Dvorak-QWERTY keycode for 'v': \(keycode ?? 0)")
    }
    
    func testFindKeycodeForV_DvorakLeftHand() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Dvorak-Left")
        if !switched {
            throw XCTSkip("Dvorak Left-Handed layout not available")
        }
        
        let keycode = ClipboardUtil.findKeycodeForCharacter("v")
        XCTAssertNotNil(keycode, "Should find keycode for 'v' in Dvorak Left-Handed layout")
        print("Dvorak Left-Handed keycode for 'v': \(keycode ?? 0)")
    }
    
    func testFindKeycodeForV_DvorakRightHand() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Dvorak-Right")
        if !switched {
            throw XCTSkip("Dvorak Right-Handed layout not available")
        }
        
        let keycode = ClipboardUtil.findKeycodeForCharacter("v")
        XCTAssertNotNil(keycode, "Should find keycode for 'v' in Dvorak Right-Handed layout")
        print("Dvorak Right-Handed keycode for 'v': \(keycode ?? 0)")
    }
    
    func testFindKeycodeForV_RussianLayout() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Russian")
        if !switched {
            throw XCTSkip("Russian layout not available")
        }
        
        let keycode = ClipboardUtil.findKeycodeForCharacter("v")
        XCTAssertNil(keycode, "Should NOT find keycode for 'v' in Russian layout (no Latin 'v')")
    }
    
    func testIsQwertyCommandLayout_USLayout() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "US")
        if !switched {
            throw XCTSkip("US layout not available")
        }
        
        XCTAssertTrue(ClipboardUtil.isQwertyCommandLayout(), "US layout should be detected as QWERTY command layout")
    }
    
    func testIsQwertyCommandLayout_DvorakQwerty() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "DVORAK-QWERTYCMD")
        if !switched {
            throw XCTSkip("Dvorak-QWERTY layout not available")
        }
        
        XCTAssertTrue(ClipboardUtil.isQwertyCommandLayout(), "Dvorak-QWERTY should be detected as QWERTY command layout")
    }
    
    func testIsQwertyCommandLayout_DvorakLeftHand() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Dvorak-Left")
        if !switched {
            throw XCTSkip("Dvorak Left-Handed layout not available")
        }
        
        XCTAssertFalse(ClipboardUtil.isQwertyCommandLayout(), "Dvorak Left-Handed should NOT be detected as QWERTY command layout")
    }
    
    func testIsQwertyCommandLayout_DvorakRightHand() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Dvorak-Right")
        if !switched {
            throw XCTSkip("Dvorak Right-Handed layout not available")
        }
        
        XCTAssertFalse(ClipboardUtil.isQwertyCommandLayout(), "Dvorak Right-Handed should NOT be detected as QWERTY command layout")
    }
}

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

// MARK: - Keyboard Layout Provider Tests

final class KeyboardLayoutProviderTests: XCTestCase {
    
    private let provider = KeyboardLayoutProvider.shared
    private var originalInputSourceID: String?
    
    override func setUpWithError() throws {
        originalInputSourceID = ClipboardUtil.getCurrentInputSourceID()
    }
    
    override func tearDownWithError() throws {
        if let originalID = originalInputSourceID {
            _ = ClipboardUtil.switchToInputSource(withID: originalID)
        }
    }
    
    // MARK: - Physical Type Detection
    
    func testDetectPhysicalType_returnsValue() {
        let physicalType = provider.detectPhysicalType()
        print("Detected physical keyboard type: \(physicalType)")
        XCTAssertTrue([.ansi, .iso, .jis].contains(physicalType))
    }
    
    // MARK: - Label Resolution
    
    func testResolveLabels_returnsLabelsForCurrentLayout() {
        let labels = provider.resolveLabels()
        XCTAssertNotNil(labels, "Should resolve labels for current layout")
        if let labels = labels {
            XCTAssertEqual(labels.count, KeyboardLayoutProvider.ansiKeycodes.count,
                           "Should have a label for every ANSI keycode")
        }
    }
    
    func testResolveLabels_USLayout_hasExpectedKeys() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "US")
        if !switched { throw XCTSkip("US layout not available") }
        
        let labels = provider.resolveLabels()
        XCTAssertNotNil(labels)
        guard let labels = labels else { return }
        
        XCTAssertEqual(labels[0], "A", "Keycode 0 should be A in US layout")
        XCTAssertEqual(labels[1], "S", "Keycode 1 should be S in US layout")
        XCTAssertEqual(labels[13], "W", "Keycode 13 should be W in US layout")
        XCTAssertEqual(labels[50], "`", "Keycode 50 should be ` in US layout")
    }
    
    func testResolveLabels_RussianLayout_hasCyrillicKeys() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Russian")
        if !switched { throw XCTSkip("Russian layout not available") }
        
        let labels = provider.resolveLabels()
        XCTAssertNotNil(labels)
        guard let labels = labels else { return }
        
        XCTAssertEqual(labels[0], "Ф", "Keycode 0 should be Ф in Russian layout")
        XCTAssertEqual(labels[1], "Ы", "Keycode 1 should be Ы in Russian layout")
    }
    
    // MARK: - resolveInfo (full validation)
    
    func testResolveInfo_USLayout_returnsInfo() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "US")
        if !switched { throw XCTSkip("US layout not available") }
        
        let info = provider.resolveInfo()
        if provider.detectPhysicalType() == .ansi {
            XCTAssertNotNil(info, "US layout on ANSI keyboard should produce info")
        }
    }
    
    func testResolveInfo_RussianLayout_returnsInfo() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Russian")
        if !switched { throw XCTSkip("Russian layout not available") }
        
        let info = provider.resolveInfo()
        if provider.detectPhysicalType() == .ansi {
            XCTAssertNotNil(info, "Russian layout on ANSI keyboard should produce info (Cyrillic labels)")
        }
    }
    
    func testResolveInfo_GermanLayout_returnsInfo() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "German")
        if !switched { throw XCTSkip("German layout not available") }
        
        let info = provider.resolveInfo()
        if provider.detectPhysicalType() == .ansi {
            XCTAssertNotNil(info, "German layout on ANSI keyboard should produce info")
        }
    }
    
    func testResolveInfo_nonANSI_returnsNil() throws {
        let physicalType = provider.detectPhysicalType()
        if physicalType != .ansi {
            let info = provider.resolveInfo()
            XCTAssertNil(info, "Non-ANSI physical keyboard should return nil from resolveInfo")
        } else {
            throw XCTSkip("This machine has ANSI keyboard, cannot test non-ANSI rejection")
        }
    }
    
    // MARK: - All Available Layouts
    
    func testResolveLabels_allAvailableLayouts() {
        let layouts = ClipboardUtil.getAvailableInputSources()
        var results: [(layout: String, labelCount: Int, success: Bool)] = []
        
        for layout in layouts {
            let switched = ClipboardUtil.switchToInputSource(withID: layout)
            guard switched else {
                results.append((layout, 0, false))
                continue
            }
            
            let labels = provider.resolveLabels()
            let count = labels?.count ?? 0
            let ok = count == KeyboardLayoutProvider.ansiKeycodes.count
            results.append((layout, count, ok))
        }
        
        print("\n=== Keyboard Layout Provider Results ===")
        for r in results {
            let status = r.success ? "OK" : "SKIP"
            print("[\(status)] \(r.layout): \(r.labelCount) labels")
        }
        print("=========================================\n")
    }
}
