// OutputDeviceClassifier.swift
// OpenSuperMLX

import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "OpenSuperMLX", category: "OutputDeviceClassifier")

// MARK: - Types

enum DeviceClassification: String, Codable, Sendable {
    case headphone
    case speaker
}

struct ClassificationEntry: Codable, Sendable {
    var classification: DeviceClassification
    var lastUsedAt: Date
    var displayName: String
}

// MARK: - Protocol

protocol OutputDeviceClassifierProtocol: AnyObject {
    @MainActor func classification(for uid: String) -> DeviceClassification?
    @MainActor func set(_ classification: DeviceClassification, for uid: String, displayName: String)
    @MainActor func markUsed(uid: String, displayName: String)
    @MainActor func recentDevices(limit: Int) -> [(uid: String, entry: ClassificationEntry)]
    @MainActor func askUser(uid: String, displayName: String) -> DeviceClassification?
}

// MARK: - Implementation

@MainActor
final class OutputDeviceClassifier: OutputDeviceClassifierProtocol {
    static let shared = OutputDeviceClassifier()

    /// Test seam: when set, askUser delegates to this closure instead of NSAlert.
    var askUserOverride: ((String, String) -> DeviceClassification?)?

    private init() {}

    // MARK: read

    func classification(for uid: String) -> DeviceClassification? {
        AppPreferences.shared.outputDeviceClassifications[uid]?.classification
    }

    func recentDevices(limit: Int = 3) -> [(uid: String, entry: ClassificationEntry)] {
        AppPreferences.shared.outputDeviceClassifications
            .map { (uid: $0.key, entry: $0.value) }
            .sorted { $0.entry.lastUsedAt > $1.entry.lastUsedAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: write

    func set(_ classification: DeviceClassification, for uid: String, displayName: String) {
        var dict = AppPreferences.shared.outputDeviceClassifications
        if var existing = dict[uid] {
            existing.classification = classification
            existing.displayName = displayName
            // lastUsedAt intentionally NOT advanced — chip-click rebrand must not promote LRU.
            dict[uid] = existing
        } else {
            dict[uid] = ClassificationEntry(
                classification: classification,
                lastUsedAt: Date(),
                displayName: displayName
            )
        }
        AppPreferences.shared.outputDeviceClassifications = dict
        NotificationCenter.default.post(name: .outputDeviceClassificationDidChange, object: nil)
    }

    func markUsed(uid: String, displayName: String) {
        var dict = AppPreferences.shared.outputDeviceClassifications
        guard var entry = dict[uid] else {
            // No-op — caller is expected to call askUser → set to obtain classification.
            return
        }
        entry.lastUsedAt = Date()
        entry.displayName = displayName
        dict[uid] = entry
        AppPreferences.shared.outputDeviceClassifications = dict
    }

    // MARK: ask

    func askUser(uid: String, displayName: String) -> DeviceClassification? {
        if let override = askUserOverride {
            return override(uid, displayName)
        }
        return Self.runClassificationAlert(displayName: displayName)
    }

    private static func runClassificationAlert(displayName: String) -> DeviceClassification? {
        let alert = NSAlert()
        alert.messageText = "Is this a headphone or external speaker?"
        alert.informativeText = """
        Device: \(displayName)

        • Headphone: sound goes directly to your ears. Won't leak into the mic — system audio can be safely mixed with mic during recording.
        • Speaker: sound plays out into the room. Will leak into the mic — system audio capture will be auto-disabled to prevent echo.
        """
        alert.addButton(withTitle: "Headphone")
        alert.addButton(withTitle: "Speaker")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:  return .headphone
        case .alertSecondButtonReturn: return .speaker
        default:                       return nil
        }
    }
}
