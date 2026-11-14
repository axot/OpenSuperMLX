// PromptPresetStore.swift
// OpenSuperMLX

import Foundation
import os.log

private let logger = Logger(subsystem: "OpenSuperMLX", category: "PromptPresetStore")

@MainActor
final class PromptPresetStore: ObservableObject {
    static let shared = PromptPresetStore()

    static let seedVersion = 1
    static let examplePresets: [PromptPreset] = [
        PromptPreset(
            name: "Fix grammar",
            instruction: "Correct grammar, spelling, punctuation, and capitalization. Keep the author's words, tone, and meaning. Return only the corrected text."
        ),
        PromptPreset(
            name: "Tighten",
            instruction: "Make the text clearer and shorter without losing facts, tone, or the author's voice. Remove repetition, filler, and unnecessary qualifiers. Keep the original structure unless a simpler one is clearly better."
        ),
        PromptPreset(
            name: "Bullet points",
            instruction: "Turn the text into a concise bullet list. One idea per bullet, keeping the original order and preserving every fact, name, number, and decision. Use plain text with “- ” bullets."
        ),
        PromptPreset(
            name: "Email",
            instruction: "Rewrite the text as a concise, courteous email body. Lead with the purpose or ask, keep one topic per short paragraph, and preserve every fact and commitment. Add a greeting or sign-off only if the text already includes one."
        ),
        PromptPreset(
            name: "Summarize",
            instruction: "Summarize the text in two or three sentences. Keep the main point, the key facts, and any decision or ask. Do not add information."
        ),
        PromptPreset(
            name: "Translate to English",
            instruction: "Translate the text into natural, fluent English. Preserve the meaning, tone, names, numbers, and formatting. Return only the translation."
        ),
    ]

    @Published private(set) var presets: [PromptPreset] = []

    private let defaults: UserDefaults
    private let storageKey = "promptPresets"
    private let seedVersionKey = "promptPresetsSeedVersion"

    init(defaults: UserDefaults = .standard, seedExamples: Bool = true) {
        self.defaults = defaults
        load()
        migrateRetiredCorrectionPrompt()
        if seedExamples {
            installExamplePresetsIfNeeded()
        }
    }

    @discardableResult
    func add(name: String, instruction: String) -> PromptPreset? {
        guard PromptPresetValidation.errorMessage(name: name, instruction: instruction) == nil else {
            return nil
        }
        let normalized = PromptPresetValidation.normalized(name: name, instruction: instruction)
        let preset = PromptPreset(name: normalized.name, instruction: normalized.instruction)
        presets.append(preset)
        persist()
        return preset
    }

    @discardableResult
    func update(id: UUID, name: String, instruction: String) -> Bool {
        guard PromptPresetValidation.errorMessage(name: name, instruction: instruction) == nil,
              let index = presets.firstIndex(where: { $0.id == id })
        else {
            return false
        }
        let normalized = PromptPresetValidation.normalized(name: name, instruction: instruction)
        presets[index].name = normalized.name
        presets[index].instruction = normalized.instruction
        persist()
        return true
    }

    func delete(id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets.remove(at: index)
        persist()
    }

    // MARK: - Retired Correction Prompt

    static let migratedPromptName = "My cleanup prompt"

    /// The LLM tab's custom correction prompt was replaced by presets. An active prompt
    /// becomes a preset and, when no other preset was chosen, the dictation cleanup.
    /// Saves without posting `promptPresetsDidChange`: this runs inside `shared`'s
    /// initializer, and observers that read `shared` would re-enter it.
    private func migrateRetiredCorrectionPrompt() {
        let custom = defaults.bool(forKey: "useCustomCorrectionPrompt")
            ? defaults.string(forKey: "customCorrectionPrompt")
            : nil
        let legacy = defaults.string(forKey: "bedrockCorrectionPrompt")
            .flatMap { $0 == LLMCorrectionService.defaultCorrectionPrompt ? nil : $0 }
        for key in ["useCustomCorrectionPrompt", "customCorrectionPrompt", "bedrockCorrectionPrompt"] {
            defaults.removeObject(forKey: key)
        }

        // The old prompt had no length limit. It is kept whole even past the preset limit,
        // which applies only when the preset is next edited.
        let normalized = PromptPresetValidation.normalized(name: Self.migratedPromptName, instruction: custom ?? legacy ?? "")
        guard !normalized.instruction.isEmpty else { return }
        let preset = PromptPreset(name: normalized.name, instruction: normalized.instruction)
        presets.append(preset)
        save()
        if defaults.bool(forKey: "llmCorrectionEnabled"), defaults.string(forKey: "dictationCleanupPresetID") == nil {
            defaults.set(preset.id.uuidString, forKey: "dictationCleanupPresetID")
        }
        logger.info("Migrated the custom correction prompt to preset \(Self.migratedPromptName, privacy: .public)")
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            presets = try JSONDecoder().decode([PromptPreset].self, from: data)
        } catch {
            logger.error("Failed to load prompt presets: \(error, privacy: .public)")
        }
    }

    private func installExamplePresetsIfNeeded() {
        guard defaults.integer(forKey: seedVersionKey) < Self.seedVersion else { return }

        let existingNames = Set(presets.map { $0.name.lowercased() })
        var added = false
        for example in Self.examplePresets where !existingNames.contains(example.name.lowercased()) {
            presets.append(example)
            added = true
        }
        defaults.set(Self.seedVersion, forKey: seedVersionKey)
        if added {
            save()
        }
    }

    private func persist() {
        save()
        NotificationCenter.default.post(name: .promptPresetsDidChange, object: self)
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(presets), forKey: storageKey)
        } catch {
            logger.error("Failed to save prompt presets: \(error, privacy: .public)")
        }
    }
}
