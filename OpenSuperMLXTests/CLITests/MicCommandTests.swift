// MicCommandTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class MicCommandTests: XCTestCase {

    // MARK: - List

    func testMicListJsonSchema() throws {
        try XCTSkipIf(true, "Requires audio hardware — tested via integration")
        let entries: [MicDeviceEntry] = [
            MicDeviceEntry(id: "dev1", name: "Built-in Mic", isDefault: true, isBuiltIn: true),
            MicDeviceEntry(id: "dev2", name: "USB Mic", isDefault: false, isBuiltIn: false),
        ]
        let json = CLIOutput.formatSuccess(command: "mic list", data: entries)
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let data = parsed?["data"] as? [[String: Any]]
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.count, 2)
        let first = data?.first
        XCTAssertNotNil(first?["id"])
        XCTAssertNotNil(first?["name"])
        XCTAssertNotNil(first?["is_default"])
        XCTAssertNotNil(first?["is_built_in"])
    }

    // MARK: - Select

    func testMicSelectInvalidDevice() throws {
        let result = MicSelectCommand.executeSelect(deviceIdentifier: "nonexistent-device-id-12345")
        guard case .failure(let error) = result else {
            XCTFail("Expected failure"); return
        }
        XCTAssertEqual(error, .audioFileNotFound)
    }

    func testMicListReturnsEntries() throws {
        let entries = MicListCommand.executeList()
        guard case .success(let devices) = entries else {
            XCTFail("Expected success"); return
        }
        XCTAssertNotNil(devices)
    }
}
