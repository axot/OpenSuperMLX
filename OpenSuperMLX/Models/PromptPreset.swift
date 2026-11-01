// PromptPreset.swift
// OpenSuperMLX

import Foundation

import KeyboardShortcuts

struct PromptPreset: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var instruction: String

    init(id: UUID = UUID(), name: String, instruction: String) {
        self.id = id
        self.name = name
        self.instruction = instruction
    }

    var shortcutName: KeyboardShortcuts.Name {
        Self.shortcutName(for: id)
    }

    static func shortcutName(for id: UUID) -> KeyboardShortcuts.Name {
        .init("promptPreset_\(id.uuidString)")
    }
}

enum PromptPresetValidation {
    static let maxNameLength = 60
    static let maxInstructionLength = 12_000

    static func errorMessage(name: String, instruction: String) -> String? {
        let normalized = normalized(name: name, instruction: instruction)
        if normalized.name.isEmpty {
            return "Give the preset a name."
        }
        if normalized.name.count > maxNameLength {
            return "Name must be \(maxNameLength) characters or fewer."
        }
        if normalized.instruction.isEmpty {
            return "Write the instruction for this preset."
        }
        if normalized.instruction.count > maxInstructionLength {
            return "Instructions must be \(maxInstructionLength) characters or fewer."
        }
        return nil
    }

    static func normalized(name: String, instruction: String) -> (name: String, instruction: String) {
        (
            name.trimmingCharacters(in: .whitespacesAndNewlines),
            instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
