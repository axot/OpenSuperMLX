//
//  PresetsPane.swift
//  OpenSuperMLX
//

import SwiftUI

import KeyboardShortcuts

struct PresetsPane: View {
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                PresetsView()
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .contentColumn()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.bg)
    }

    private var header: some View {
        HStack {
            Text("Presets")
                .font(.system(size: 18, weight: .bold))
                .tracking(DesignTokens.trackingTitle * 18)
                .foregroundStyle(DesignTokens.txt)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .contentColumn(alignment: .leading)
    }
}

struct PresetsView: View {
    @ObservedObject private var store = PromptPresetStore.shared

    @State private var editingID: UUID?
    @State private var isCreating = false
    @State private var draftName = ""
    @State private var draftInstruction = ""
    @State private var editorError: String?
    @State private var pendingDeletion: PromptPreset?
    @State private var alwaysReplace = AppPreferences.shared.presetsAlwaysReplace

    var body: some View {
        VStack(spacing: 22) {
            presetsGroup
            if isCreating || editingID != nil {
                editorGroup
            }
            replacementGroup
            usageGroup
        }
        .onChange(of: alwaysReplace) { _, newValue in
            AppPreferences.shared.presetsAlwaysReplace = newValue
        }
        .confirmationDialog(
            "Delete preset?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { preset in
            Button("Delete “\(preset.name)”", role: .destructive) {
                store.delete(id: preset.id)
                if editingID == preset.id {
                    endEditing()
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text("This removes the preset and its shortcut.")
        }
    }

    // MARK: - Presets

    private var presetsGroup: some View {
        SettingsGroup(title: "Your Presets") {
            if store.presets.isEmpty {
                Text("No presets yet. Add one below.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DesignTokens.txt3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
            } else {
                ForEach(store.presets) { preset in
                    presetRow(preset)
                    SettingsFieldDivider()
                }
            }

            SettingsField(label: "New preset", detail: "Name it, write the instruction, then assign a shortcut") {
                addButton
            }
        }
    }

    private func presetRow(_ preset: PromptPreset) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.txt)
                Text(preset.instruction.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(DesignTokens.txt3)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            KeyboardShortcuts.Recorder("", name: preset.shortcutName)
                .shortcutValidation { shortcut in
                    MainActor.assumeIsolated {
                        validationResult(for: preset, shortcut: shortcut)
                    }
                }
                .frame(width: 150)

            iconButton("pencil", help: "Edit preset") {
                beginEditing(preset)
            }
            iconButton("trash", help: "Delete preset") {
                pendingDeletion = preset
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var addButton: some View {
        Button {
            beginCreating()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                Text("Add Preset").font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(DesignTokens.txt)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(DesignTokens.surface3))
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DesignTokens.txt2)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DesignTokens.surface3))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Editor

    private var editorGroup: some View {
        SettingsGroup(title: editingID == nil ? "New Preset" : "Edit Preset") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("", text: $draftName, prompt: Text("Preset name"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DesignTokens.surface3))

                TextEditor(text: $draftInstruction)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 150)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DesignTokens.surface3))

                if let editorError {
                    Text(editorError)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DesignTokens.red)
                }

                Text("Save first, then record the shortcut on the preset's row.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.txt3)

                HStack(spacing: 8) {
                    Spacer()
                    secondaryButton("Cancel") {
                        endEditing()
                    }
                    primaryButton(editingID == nil ? "Add Preset" : "Save") {
                        saveDraft()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DesignTokens.txt)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(DesignTokens.surface3))
        }
        .buttonStyle(.plain)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DesignTokens.accOn)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(DesignTokens.acc))
        }
        .buttonStyle(.plain)
    }

    private var replacementGroup: some View {
        SettingsGroup(title: "Replacing Text") {
            SettingsField(
                label: "Always replace automatically",
                detail: "Some apps don't let OpenSuperMLX check that your text is still selected. Turn this off to get the rewrite on the clipboard in those apps and paste it yourself."
            ) {
                DesignToggle(isOn: $alwaysReplace)
            }
        }
    }

    private var usageGroup: some View {
        SettingsGroup(title: "How It Works") {
            VStack(alignment: .leading, spacing: 7) {
                Text("Select text in any app, then press a preset's shortcut. The model rewrites the selection in place.")
                Text("Presets use the provider and model configured in the LLM tab. Accessibility access is required to read and replace the selection.")
            }
            .font(.system(size: 12))
            .foregroundStyle(DesignTokens.txt2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }

    // MARK: - Actions

    private func beginCreating() {
        editingID = nil
        isCreating = true
        draftName = ""
        draftInstruction = ""
        editorError = nil
    }

    private func beginEditing(_ preset: PromptPreset) {
        editingID = preset.id
        isCreating = false
        draftName = preset.name
        draftInstruction = preset.instruction
        editorError = nil
    }

    private func endEditing() {
        editingID = nil
        isCreating = false
        draftName = ""
        draftInstruction = ""
        editorError = nil
    }

    private func saveDraft() {
        if let message = PromptPresetValidation.errorMessage(name: draftName, instruction: draftInstruction) {
            editorError = message
            return
        }
        if let editingID {
            store.update(id: editingID, name: draftName, instruction: draftInstruction)
        } else {
            store.add(name: draftName, instruction: draftInstruction)
        }
        endEditing()
    }

    private func validationResult(
        for preset: PromptPreset,
        shortcut: KeyboardShortcuts.Shortcut
    ) -> KeyboardShortcuts.ValidationResult {
        if let other = store.presets.first(where: {
            $0.id != preset.id && $0.shortcutName.shortcut == shortcut
        }) {
            return .disallow(reason: "Already used by “\(other.name)”.")
        }
        if let owner = ShortcutManager.builtInShortcutOwner(of: shortcut, excluding: nil) {
            return .disallow(reason: "Already used by \(owner).")
        }
        return .allow
    }
}
