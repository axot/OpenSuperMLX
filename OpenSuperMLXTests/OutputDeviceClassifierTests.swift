// OutputDeviceClassifierTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

@MainActor
final class OutputDeviceClassifierTests: XCTestCase {
    private var defaults: UserDefaults!
    private var classifier: OutputDeviceClassifier!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "OutputDeviceClassifierTests")!
        defaults.removePersistentDomain(forName: "OutputDeviceClassifierTests")
        AppPreferences.store = defaults
        classifier = OutputDeviceClassifier.shared
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: "OutputDeviceClassifierTests")
        AppPreferences.store = .standard
        defaults = nil
        classifier = nil
        try await super.tearDown()
    }

    // MARK: - 1. Storage round-trip

    func testStoresAndRetrievesClassification() {
        classifier.set(.headphone, for: "uid-1", displayName: "AirPods Pro")
        XCTAssertEqual(classifier.classification(for: "uid-1"), .headphone)

        classifier.set(.speaker, for: "uid-2", displayName: "Built-in Speakers")
        XCTAssertEqual(classifier.classification(for: "uid-2"), .speaker)
    }

    // MARK: - 2. markUsed only updates lastUsedAt

    func testMarkUsedDoesNotChangeClassification() {
        classifier.set(.headphone, for: "uid-1", displayName: "AirPods Pro")
        let before = classifier.recentDevices(limit: 10).first { $0.uid == "uid-1" }?.entry.lastUsedAt
        XCTAssertNotNil(before)

        Thread.sleep(forTimeInterval: 0.01)
        classifier.markUsed(uid: "uid-1", displayName: "AirPods Pro")

        XCTAssertEqual(classifier.classification(for: "uid-1"), .headphone)
        let after = classifier.recentDevices(limit: 10).first { $0.uid == "uid-1" }?.entry.lastUsedAt
        XCTAssertNotNil(after)
        XCTAssertGreaterThan(after!, before!)
    }

    // MARK: - 3. recentDevices LRU

    func testRecentDevicesLimitsToThree() {
        let now = Date()
        for i in 0..<5 {
            classifier.set(.headphone, for: "uid-\(i)", displayName: "Device \(i)")
            // Backdate so each one's lastUsedAt is unique and ordered
            var dict = AppPreferences.shared.outputDeviceClassifications
            dict["uid-\(i)"]?.lastUsedAt = now.addingTimeInterval(TimeInterval(i))
            AppPreferences.shared.outputDeviceClassifications = dict
        }

        let recent = classifier.recentDevices(limit: 3)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.map { $0.uid }, ["uid-4", "uid-3", "uid-2"])
    }

    // MARK: - 4. recentDevices empty when no entries

    func testRecentDevicesEmptyWhenNoEntries() {
        XCTAssertTrue(classifier.recentDevices(limit: 3).isEmpty)
    }

    // MARK: - 5. set updates classification but not lastUsedAt for existing entries

    func testSetClassificationDoesNotUpdateLastUsedAtForExisting() {
        classifier.set(.headphone, for: "uid-1", displayName: "X")
        let firstStamp = classifier.recentDevices(limit: 10).first?.entry.lastUsedAt
        XCTAssertNotNil(firstStamp)

        Thread.sleep(forTimeInterval: 0.01)
        classifier.set(.speaker, for: "uid-1", displayName: "X")

        XCTAssertEqual(classifier.classification(for: "uid-1"), .speaker)
        let secondStamp = classifier.recentDevices(limit: 10).first?.entry.lastUsedAt
        XCTAssertEqual(firstStamp, secondStamp,
                       "set() on existing entry must not advance lastUsedAt")
    }

    // MARK: - 6. corrupted storage recovers to empty

    func testCorruptedStorageRecoversToEmpty() {
        defaults.set(Data([0xFF, 0xFE, 0xFD, 0xFC]), forKey: "outputDeviceClassifications")

        XCTAssertTrue(AppPreferences.shared.outputDeviceClassifications.isEmpty)
        XCTAssertNil(classifier.classification(for: "any-uid"))
    }

    // MARK: - 7. cancelled modal does not persist

    func testAskUserCancelDoesNotPersist() {
        // Inject a stub that returns nil (cancel)
        let stub = StubAsker(answer: nil)
        classifier.askUserOverride = stub.ask

        let result = classifier.askUser(uid: "uid-x", displayName: "Mystery Device")

        XCTAssertNil(result)
        XCTAssertNil(classifier.classification(for: "uid-x"))
        XCTAssertTrue(classifier.recentDevices(limit: 10).isEmpty)
    }

    // MARK: - 8. set creating new entry stamps lastUsedAt to now

    func testSetCreatingNewEntryStampsLastUsedAt() {
        let before = Date()
        classifier.set(.headphone, for: "fresh-uid", displayName: "Fresh")
        let after = Date()

        let stamp = classifier.recentDevices(limit: 10).first { $0.uid == "fresh-uid" }?.entry.lastUsedAt
        XCTAssertNotNil(stamp)
        XCTAssertGreaterThanOrEqual(stamp!, before)
        XCTAssertLessThanOrEqual(stamp!, after)
    }
}

private final class StubAsker {
    let answer: DeviceClassification?
    init(answer: DeviceClassification?) { self.answer = answer }
    func ask(uid: String, displayName: String) -> DeviceClassification? { answer }
}
