// DiagnoseCommandTests.swift
// OpenSuperMLXTests

import XCTest

import ArgumentParser
@testable import OpenSuperMLX

final class DiagnoseCommandTests: XCTestCase {

    // MARK: - Output Content

    func testDiagnoseIncludesMacOSVersion() {
        let result = DiagnoseCommand.collectDiagnostics()
        XCTAssertFalse(result.macosVersion.isEmpty)
        XCTAssertTrue(result.macosVersion.contains("Version"))
    }

    func testDiagnoseIncludesChipModel() {
        let result = DiagnoseCommand.collectDiagnostics()
        XCTAssertFalse(result.chipModel.isEmpty)
    }

    func testDiagnoseIncludesMemory() {
        let result = DiagnoseCommand.collectDiagnostics()
        XCTAssertGreaterThan(result.availableMemoryGB, 0.0)
    }

    // MARK: - JSON Output

    func testDiagnoseJSONOutputStructure() throws {
        let result = DiagnoseCommand.collectDiagnostics()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNotNil(json["macos_version"] as? String)
        XCTAssertNotNil(json["chip_model"] as? String)
        XCTAssertNotNil(json["available_memory_gb"] as? Double)
        XCTAssertNotNil(json["installed_models"] as? [String])
        XCTAssertNotNil(json["permissions"] as? [String: Any])
        XCTAssertNotNil(json["settings"] as? [String: Any])
    }

    // MARK: - Option Parsing

    func testDiagnoseParses() throws {
        let command = try DiagnoseCommand.parse([])
        XCTAssertNotNil(command)
    }
}
