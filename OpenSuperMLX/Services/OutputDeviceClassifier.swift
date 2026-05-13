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

/// Fallback display name when the OS doesn't expose `kAudioDevicePropertyDeviceNameCFString`
/// for a device — show enough of the UID to be identifiable but short enough to fit in
/// a popover row alongside the chip button.
func fallbackDisplayName(forUID uid: String) -> String {
    String(uid.prefix(16))
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

    /// In-memory cache of the persisted dictionary. Reads (`classification(for:)`,
    /// `recentDevices`) are on hot UI paths (toolbar badge, popover); without this
    /// cache they would JSON-decode the full `[String: ClassificationEntry]` from
    /// UserDefaults on every call.
    private var cache: [String: ClassificationEntry]

    private init() {
        cache = AppPreferences.shared.outputDeviceClassifications
    }

    /// Test-only: drop the in-memory cache so the next read re-loads from UserDefaults.
    /// Tests swap `AppPreferences.store`; without this they'd see stale data.
    func resetCacheForTesting() {
        cache = AppPreferences.shared.outputDeviceClassifications
    }

    // MARK: read

    func classification(for uid: String) -> DeviceClassification? {
        cache[uid]?.classification
    }

    func recentDevices(limit: Int) -> [(uid: String, entry: ClassificationEntry)] {
        cache
            .map { (uid: $0.key, entry: $0.value) }
            .sorted { $0.entry.lastUsedAt > $1.entry.lastUsedAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: write

    /// `set` posts `.outputDeviceClassificationDidChange` so the popover UI refreshes
    /// its chips. `markUsed` deliberately does NOT post — LRU promotion is invisible
    /// to the user (the popover only re-orders by recency, the displayed labels and
    /// classifications are unchanged), so notifying would force pointless re-renders.
    func set(_ classification: DeviceClassification, for uid: String, displayName: String) {
        if var existing = cache[uid] {
            existing.classification = classification
            existing.displayName = displayName
            // lastUsedAt intentionally NOT advanced — chip-click rebrand must not promote LRU.
            cache[uid] = existing
        } else {
            cache[uid] = ClassificationEntry(
                classification: classification,
                lastUsedAt: Date(),
                displayName: displayName
            )
        }
        AppPreferences.shared.outputDeviceClassifications = cache
        NotificationCenter.default.post(name: .outputDeviceClassificationDidChange, object: nil)
    }

    func markUsed(uid: String, displayName: String) {
        guard var entry = cache[uid] else {
            // No-op — caller is expected to call askUser → set to obtain classification.
            return
        }
        entry.lastUsedAt = Date()
        entry.displayName = displayName
        cache[uid] = entry
        AppPreferences.shared.outputDeviceClassifications = cache
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
