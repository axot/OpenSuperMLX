// CorrectCommandTests.swift
// OpenSuperMLXTests

import XCTest

import ArgumentParser
@testable import OpenSuperMLX

@MainActor
final class CorrectCommandTests: XCTestCase {

    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "com.opensupermlx.test.correct.\(name)")!
        testDefaults.removePersistentDomain(forName: "com.opensupermlx.test.correct.\(name)")
        AppPreferences.store = testDefaults
    }

    override func tearDown() {
        AppPreferences.store = .standard
        testDefaults.removePersistentDomain(forName: "com.opensupermlx.test.correct.\(name)")
        testDefaults = nil
        super.tearDown()
    }

    // MARK: - Argument Parsing

    func testCorrectCommandParseTextArgument() throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(
            ["correct", "hello world"]
        ) as! CorrectCommand
        XCTAssertEqual(command.text, "hello world")
        XCTAssertNil(command.file)
    }

    func testCorrectCommandParseProviderFlag() throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(
            ["correct", "text", "--provider", "bedrock"]
        ) as! CorrectCommand
        XCTAssertEqual(command.text, "text")
        XCTAssertEqual(command.provider, "bedrock")
    }

    func testCorrectCommandParseFileOption() throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(
            ["correct", "placeholder", "--file", "/tmp/test.txt"]
        ) as! CorrectCommand
        XCTAssertEqual(command.file, "/tmp/test.txt")
    }

    // MARK: - Execution

    func testCorrectWithMockProvider() async throws {
        let mockProvider = MockLLMProvider()
        let service = LLMCorrectionService(providerFactory: { mockProvider })

        let command = try OpenSuperMLXCLI.parseAsRoot(
            ["correct", "um hello world"]
        ) as! CorrectCommand

        for output in ["cleaned up text", "um hello world"] {
            mockProvider.correctResult = output
            let result = await command.executeCorrection(service: service)

            guard case .success(let data) = result else {
                XCTFail("Expected success"); return
            }
            XCTAssertEqual(data.correctedText, output)
            XCTAssertEqual(data.originalText, "um hello world")
        }
        XCTAssertEqual(mockProvider.correctCallCount, 2)
    }

    func testCorrectFileNotFound() async throws {
        let mockProvider = MockLLMProvider()
        let service = LLMCorrectionService(providerFactory: { mockProvider })

        let command = try OpenSuperMLXCLI.parseAsRoot(
            ["correct", "placeholder", "--file", "/nonexistent/path.txt"]
        ) as! CorrectCommand

        let result = await command.executeCorrection(service: service)

        guard case .failure(let error) = result else {
            XCTFail("Expected failure"); return
        }
        XCTAssertEqual(error, .audioFileNotFound)
    }

    func testCorrectProviderNotConfigured() async throws {
        let mockProvider = MockLLMProvider()
        mockProvider.isConfigured = false
        let service = LLMCorrectionService(providerFactory: { mockProvider })

        let command = try OpenSuperMLXCLI.parseAsRoot(
            ["correct", "hello world"]
        ) as! CorrectCommand

        let result = await command.executeCorrection(service: service)

        guard case .failure(let error) = result else {
            XCTFail("Expected correction failure"); return
        }
        XCTAssertEqual(error, .llmCorrectionFailed)
        XCTAssertEqual(mockProvider.correctCallCount, 0)
    }

    func testCorrectProviderFailuresReturnError() async throws {
        let command = try OpenSuperMLXCLI.parseAsRoot(
            ["correct", "hello world"]
        ) as! CorrectCommand

        let cases: [(response: String, error: Error?)] = [
            ("", nil),
            ("<transcription> </transcription>", nil),
            ("hello world", LLMProviderError.networkError(underlying: URLError(.notConnectedToInternet))),
        ]
        for testCase in cases {
            let mockProvider = MockLLMProvider()
            mockProvider.correctResult = testCase.response
            mockProvider.shouldThrowError = testCase.error
            let service = LLMCorrectionService(providerFactory: { mockProvider })

            let result = await command.executeCorrection(service: service)

            guard case .failure(let error) = result else {
                XCTFail("Expected correction failure for \(testCase)"); continue
            }
            XCTAssertEqual(error, .llmCorrectionFailed)
            XCTAssertEqual(mockProvider.correctCallCount, 1)
        }
    }

    func testCorrectWithCustomPrompt() async throws {
        let mockProvider = MockLLMProvider()
        mockProvider.correctResult = "fixed"
        let service = LLMCorrectionService(providerFactory: { mockProvider })

        let command = try OpenSuperMLXCLI.parseAsRoot(
            ["correct", "test input", "--prompt", "Fix grammar only"]
        ) as! CorrectCommand

        let result = await command.executeCorrection(service: service)

        guard case .success = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertTrue(AppPreferences.shared.useCustomCorrectionPrompt)
        XCTAssertEqual(AppPreferences.shared.customCorrectionPrompt, "Fix grammar only")
    }
}
