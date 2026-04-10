// ConfigCommandTests.swift
// OpenSuperMLXTests

import XCTest

import ArgumentParser
@testable import OpenSuperMLX

@MainActor
final class ConfigCommandTests: XCTestCase {

    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "com.opensupermlx.test.config.\(name)")!
        testDefaults.removePersistentDomain(forName: "com.opensupermlx.test.config.\(name)")
        AppPreferences.store = testDefaults
    }

    override func tearDown() {
        AppPreferences.store = .standard
        testDefaults.removePersistentDomain(forName: "com.opensupermlx.test.config.\(name)")
        testDefaults = nil
        super.tearDown()
    }

    // MARK: - List

    func testConfigListOutputsAllKeys() throws {
        let result = ConfigListCommand.executeList()
        guard case .success(let entries) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertGreaterThanOrEqual(entries.count, 20)

        let keys = entries.map(\.key)
        XCTAssertTrue(keys.contains("mlxLanguage"))
        XCTAssertTrue(keys.contains("temperature"))
        XCTAssertTrue(keys.contains("llmCorrectionEnabled"))
    }

    func testConfigListMasksSensitiveKeys() throws {
        testDefaults.set("my-secret-key", forKey: "bedrockAccessKey")
        testDefaults.set("api-key-123", forKey: "openAIAPIKey")

        let result = ConfigListCommand.executeList()
        guard case .success(let entries) = result else {
            XCTFail("Expected success"); return
        }

        let bedrockEntry = entries.first { $0.key == "bedrockAccessKey" }
        XCTAssertEqual(bedrockEntry?.value, "***")

        let openAIEntry = entries.first { $0.key == "openAIAPIKey" }
        XCTAssertEqual(openAIEntry?.value, "***")
    }

    // MARK: - Get

    func testConfigGetExistingKey() throws {
        testDefaults.set("zh", forKey: "mlxLanguage")

        let result = ConfigGetCommand.executeGet(key: "mlxLanguage")
        guard case .success(let entry) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertEqual(entry.key, "mlxLanguage")
        XCTAssertEqual(entry.value, "zh")
        XCTAssertEqual(entry.type, "String")
    }

    func testConfigGetInvalidKey() throws {
        let result = ConfigGetCommand.executeGet(key: "nonExistentKey")
        guard case .failure(let error) = result else {
            XCTFail("Expected failure"); return
        }
        XCTAssertEqual(error, .invalidConfigKey)
    }

    // MARK: - Set

    func testConfigSetStringValue() throws {
        let result = ConfigSetCommand.executeSet(key: "mlxLanguage", value: "zh")
        guard case .success = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertEqual(testDefaults.string(forKey: "mlxLanguage"), "zh")
    }

    func testConfigSetBoolValue() throws {
        let result = ConfigSetCommand.executeSet(key: "llmCorrectionEnabled", value: "true")
        guard case .success = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertEqual(testDefaults.bool(forKey: "llmCorrectionEnabled"), true)
    }

    func testConfigSetDoubleValue() throws {
        let result = ConfigSetCommand.executeSet(key: "temperature", value: "0.5")
        guard case .success = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertEqual(testDefaults.double(forKey: "temperature"), 0.5, accuracy: 0.001)
    }

    func testConfigSetInvalidKey() throws {
        let result = ConfigSetCommand.executeSet(key: "nonExistentKey", value: "whatever")
        guard case .failure(let error) = result else {
            XCTFail("Expected failure"); return
        }
        XCTAssertEqual(error, .invalidConfigKey)
    }

    func testConfigSetInvalidBoolValue() throws {
        let result = ConfigSetCommand.executeSet(key: "llmCorrectionEnabled", value: "notabool")
        guard case .failure(let error) = result else {
            XCTFail("Expected failure"); return
        }
        XCTAssertEqual(error, .invalidConfigValue)
    }

    func testConfigSetInvalidDoubleValue() throws {
        let result = ConfigSetCommand.executeSet(key: "temperature", value: "notanumber")
        guard case .failure(let error) = result else {
            XCTFail("Expected failure"); return
        }
        XCTAssertEqual(error, .invalidConfigValue)
    }

    func testConfigSetOptionalToNull() throws {
        testDefaults.set("custom prompt", forKey: "customCorrectionPrompt")

        let result = ConfigSetCommand.executeSet(key: "customCorrectionPrompt", value: "null")
        guard case .success = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertNil(testDefaults.string(forKey: "customCorrectionPrompt"))
    }
}
