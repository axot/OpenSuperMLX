// DictationCleanup.swift
// OpenSuperMLX

import Foundation

enum DictationCleanup: Equatable, Identifiable {
    case raw
    case clean
    case preset(PromptPreset)

    var id: String {
        switch self {
        case .raw: return "raw"
        case .clean: return "clean"
        case .preset(let preset): return preset.id.uuidString
        }
    }

    var title: String {
        switch self {
        case .raw: return "Raw"
        case .clean: return "Clean"
        case .preset(let preset): return preset.name
        }
    }

    var hint: String {
        switch self {
        case .raw: return "Exactly what was heard"
        case .clean: return "Fillers out, punctuation fixed"
        case .preset: return ""
        }
    }

    var preset: PromptPreset? {
        if case .preset(let preset) = self { return preset }
        return nil
    }

    static func choices(presets: [PromptPreset]) -> [DictationCleanup] {
        [.raw, .clean] + presets.map { .preset($0) }
    }

    // MARK: - Persistence

    @MainActor
    static var current: DictationCleanup {
        current(presets: PromptPresetStore.shared.presets)
    }

    @MainActor
    static func current(presets: [PromptPreset]) -> DictationCleanup {
        let prefs = AppPreferences.shared
        guard prefs.llmCorrectionEnabled else { return .raw }
        guard let id = prefs.dictationCleanupPresetID,
              let preset = presets.first(where: { $0.id.uuidString == id })
        else {
            return .clean
        }
        return .preset(preset)
    }

    /// Raw turns LLM correction off; any other choice turns it on, so the Settings
    /// toggle and the pill never disagree.
    @MainActor
    func select() {
        let prefs = AppPreferences.shared
        prefs.llmCorrectionEnabled = self != .raw
        if self != .raw {
            prefs.dictationCleanupPresetID = preset?.id.uuidString
        }
        NotificationCenter.default.post(name: .dictationCleanupDidChange, object: nil)
    }
}
