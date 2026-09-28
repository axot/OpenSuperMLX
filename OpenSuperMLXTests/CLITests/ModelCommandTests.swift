// ModelCommandTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

@MainActor
final class ModelCommandTests: XCTestCase {

    // MARK: - List

    func testModelListReportsTheSingleBuiltInModel() throws {
        guard case .success(let entries) = ModelListCommand.executeList() else {
            XCTFail("Expected success"); return
        }
        XCTAssertEqual(entries.map(\.repoId), ["mlx-community/Qwen3-ASR-1.7B-5bit"])
    }

    // MARK: - Removed Subcommands

    func testModelSelectionSubcommandsAreRemoved() {
        for subcommand in ["select", "add", "remove", "download"] {
            XCTAssertThrowsError(try OpenSuperMLXCLI.parseAsRoot(["model", subcommand, "x"]), subcommand)
        }
    }
}
