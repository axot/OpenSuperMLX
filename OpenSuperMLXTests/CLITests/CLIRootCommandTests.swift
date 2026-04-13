// CLIRootCommandTests.swift
// OpenSuperMLXTests

import XCTest

import ArgumentParser
@testable import OpenSuperMLX

final class CLIRootCommandTests: XCTestCase {

    // MARK: - Subcommand Routing

    func testParseTranscribeSubcommand() throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(["transcribe", "file.wav"])
        XCTAssertTrue(command is TranscribeCommand)
    }

    func testParseStreamSimulateSubcommand() throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(["stream-simulate", "file.wav"])
        XCTAssertTrue(command is StreamSimulateCommand)
    }

    func testParseDiagnoseSubcommand() throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(["diagnose"])
        XCTAssertTrue(command is DiagnoseCommand)
    }

    // MARK: - Global Flags

    func testJsonFlagParsed() throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(["diagnose", "--json"])
        guard let diagnose = command as? DiagnoseCommand else {
            XCTFail("Expected DiagnoseCommand"); return
        }
        XCTAssertTrue(diagnose.globalOptions.json)
    }

    func testQuietFlagParsed() throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(["diagnose", "--quiet"])
        guard let diagnose = command as? DiagnoseCommand else {
            XCTFail("Expected DiagnoseCommand"); return
        }
        XCTAssertTrue(diagnose.globalOptions.quiet)
    }

    func testVerboseFlagParsed() throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(["diagnose", "--verbose"])
        guard let diagnose = command as? DiagnoseCommand else {
            XCTFail("Expected DiagnoseCommand"); return
        }
        XCTAssertTrue(diagnose.globalOptions.verbose)
    }

    // MARK: - Invalid Input

    func testInvalidSubcommandThrows() {
        XCTAssertThrowsError(try OpenSuperMLXCLI.parseAsRoot(["nonexistent"]))
    }
}
