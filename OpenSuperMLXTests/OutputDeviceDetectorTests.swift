// OutputDeviceDetectorTests.swift
// OpenSuperMLX

import XCTest

@testable import OpenSuperMLX

final class OutputDeviceDetectorTests: XCTestCase {

    // MARK: - Transport Type Mapping

    private let bluetooth: UInt32 = 1651275109  // "blue"
    private let usb: UInt32 = 1970496032        // "usb "
    private let builtIn: UInt32 = 1651274862    // "bltn"
    private let ispk: UInt32 = 1769173099       // "ispk"
    private let hdpn: UInt32 = 1751412846       // "hdpn"

    func testBluetoothMapsToHeadphones() {
        let result = OutputDeviceDetector.mapTransportType(bluetooth, dataSource: nil)
        XCTAssertEqual(result, .headphones)
    }

    func testUSBMapsToHeadphones() {
        let result = OutputDeviceDetector.mapTransportType(usb, dataSource: nil)
        XCTAssertEqual(result, .headphones)
    }

    func testBuiltInWithISPKMapsToSpeakers() {
        let result = OutputDeviceDetector.mapTransportType(builtIn, dataSource: ispk)
        XCTAssertEqual(result, .speakers)
    }

    func testBuiltInWithHDPNMapsToHeadphones() {
        let result = OutputDeviceDetector.mapTransportType(builtIn, dataSource: hdpn)
        XCTAssertEqual(result, .headphones)
    }

    func testUnknownTransportTypeMapsToUnknown() {
        let result = OutputDeviceDetector.mapTransportType(0, dataSource: nil)
        XCTAssertEqual(result, .unknown)
    }
}
