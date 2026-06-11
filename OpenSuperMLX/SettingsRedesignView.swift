//
//  SettingsRedesignView.swift
//  OpenSuperMLX
//
//  Sidebar-embedded settings matching the finalized mockup: pill sub-tabs,
//  fields grouped into rounded cards. Reuses SettingsViewModel for all bindings.
//

import SwiftUI

import KeyboardShortcuts

// MARK: - Sub-tab

enum SettingsSubtab: Int, CaseIterable, Identifiable {
    case shortcuts, model, transcription, advanced, llm
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .shortcuts: return "Shortcuts"
        case .model: return "Model"
        case .transcription: return "Transcription"
        case .advanced: return "Advanced"
        case .llm: return "LLM"
        }
    }
    var systemImage: String {
        switch self {
        case .shortcuts: return "command"
        case .model: return "cpu"
        case .transcription: return "text.bubble"
        case .advanced: return "gearshape"
        case .llm: return "brain"
        }
    }
}

// MARK: - Root

struct SettingsRedesignView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var modelManager: MLXModelManager
    @State private var subtab: SettingsSubtab = .shortcuts
    @State private var customModelInput = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            pills
            ScrollView(showsIndicators: false) {
                Group {
                    switch subtab {
                    case .shortcuts: shortcutsTab
                    case .model: modelTab
                    case .transcription: transcriptionTab
                    case .advanced: advancedTab
                    case .llm: llmTab
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.bg)
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 18, weight: .bold))
                .tracking(DesignTokens.trackingTitle * 18)
                .foregroundStyle(DesignTokens.txt)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var pills: some View {
        HStack(spacing: 3) {
            ForEach(SettingsSubtab.allCases) { tab in
                Button { subtab = tab } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(subtab == tab ? DesignTokens.acc : DesignTokens.txt3)
                        Text(tab.label)
                            .font(.system(size: 12.5, weight: subtab == tab ? .semibold : .medium))
                            .foregroundStyle(subtab == tab ? DesignTokens.txt : DesignTokens.txt2)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background {
                        if subtab == tab {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(DesignTokens.surface)
                                .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.label)
                .accessibilityAddTraits(subtab == tab ? .isSelected : [])
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: DesignTokens.radiusSearch, style: .continuous).fill(DesignTokens.surface3))
        .padding(.horizontal, 22)
    }

    // MARK: - Shortcuts

    private var shortcutsTab: some View {
        VStack(spacing: 22) {
            SettingsGroup(title: "Recording Trigger") {
                SettingsField(label: "Toggle record shortcut") {
                    KeyboardShortcuts.Recorder("", name: .toggleRecord).frame(width: 150)
                }
                SettingsFieldDivider()
                SettingsField(label: "Record with LLM cleanup") {
                    KeyboardShortcuts.Recorder("", name: .toggleRecordWithLLM).frame(width: 150)
                }
            }
            SettingsGroup(title: "Recording Behavior") {
                SettingsField(label: "Play sound when recording starts") {
                    DesignToggle(isOn: $viewModel.playSoundOnRecordStart)
                }
            }
            SettingsGroup(title: "Privacy") {
                SettingsField(label: "On-device transcription", detail: "Audio never leaves your Mac") {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                        Text("Always on").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(DesignTokens.green)
                }
            }
        }
    }

    // MARK: - Model

    private var modelTab: some View {
        VStack(spacing: 22) {
            SettingsGroup(title: "MLX Speech Recognition Model") {
                ForEach(Array(modelManager.availableModels.enumerated()), id: \.element.id) { idx, model in
                    if idx > 0 { SettingsFieldDivider() }
                    ModelRow(
                        model: model,
                        isSelected: viewModel.selectedMLXModel == model.repoID,
                        onSelect: { viewModel.selectedMLXModel = model.repoID },
                        onDelete: model.isCustom ? {
                            if viewModel.selectedMLXModel == model.repoID {
                                viewModel.selectedMLXModel = MLXModelManager.builtInModels[1].repoID
                            }
                            modelManager.removeCustomModel(model)
                        } : nil
                    )
                }
            }
            SettingsGroup(title: "Custom Model") {
                SettingsField(label: "Add from HuggingFace", detail: "Enter repo ID or URL") {
                    HStack(spacing: 8) {
                        TextField("mlx-community/…", text: $customModelInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .frame(width: 180)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .fieldSurface()
                            .onSubmit(addCustomModel)
                        Button("Add", action: addCustomModel)
                            .controlSize(.small)
                            .disabled(customModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            SettingsGroup(title: "Models Directory") {
                SettingsField(label: directoryDisplay(MLXModelManager.modelsDirectory.appendingPathComponent("mlx-audio"))) {
                    OpenFolderButton {
                        let dir = MLXModelManager.modelsDirectory.appendingPathComponent("mlx-audio")
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                }
            }
        }
    }

    private func addCustomModel() {
        modelManager.addCustomModel(repoID: customModelInput)
        customModelInput = ""
    }

    // MARK: - Transcription

    private var transcriptionTab: some View {
        VStack(spacing: 22) {
            SettingsGroup(title: "Language") {
                SettingsField(label: "Transcription language") {
                    Picker("", selection: $viewModel.selectedLanguage) {
                        ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                            Text(LanguageUtil.languageNames[code] ?? code).tag(code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                SettingsFieldDivider()
                SettingsField(label: "Translate to English") {
                    DesignToggle(isOn: $viewModel.translateToEnglish)
                }
                if Settings.asianLanguages.contains(viewModel.selectedLanguage) {
                    SettingsFieldDivider()
                    SettingsField(label: "Asian autocorrect", detail: "Fix spacing & punctuation") {
                        DesignToggle(isOn: $viewModel.useAsianAutocorrect)
                    }
                }
            }
            SettingsGroup(title: "Streaming") {
                SettingsField(label: "Streaming transcription", detail: "Transcribe in real-time while recording") {
                    DesignToggle(isOn: $viewModel.useStreamingTranscription)
                }
            }
            SettingsGroup(title: "Transcriptions Directory") {
                SettingsField(label: directoryDisplay(Recording.recordingsDirectory)) {
                    OpenFolderButton { NSWorkspace.shared.open(Recording.recordingsDirectory) }
                }
            }
        }
    }

    // MARK: - Advanced

    private var advancedTab: some View {
        VStack(spacing: 22) {
            PermissionsCard()
            SettingsGroup(title: "Model Parameters") {
                SettingsField(label: "Temperature") {
                    HStack(spacing: 12) {
                        Slider(value: $viewModel.temperature, in: 0...1, step: 0.1)
                            .frame(width: 160)
                        Text(String(format: "%.2f", viewModel.temperature))
                            .font(.system(size: 12.5).monospacedDigit())
                            .foregroundStyle(DesignTokens.txt2)
                    }
                }
            }
            SettingsGroup(title: "Debug") {
                SettingsField(label: "Debug mode", detail: "Extra logging") {
                    DesignToggle(isOn: $viewModel.debugMode)
                }
            }
        }
    }

    // MARK: - LLM

    private var llmTab: some View {
        VStack(spacing: 22) {
            SettingsGroup(title: "LLM Correction") {
                SettingsField(label: "Enable LLM cleanup", detail: "Use an LLM to clean up output") {
                    DesignToggle(isOn: $viewModel.llmCorrectionEnabled)
                }
                SettingsFieldDivider()
                SettingsField(label: "Provider") {
                    Picker("", selection: $viewModel.llmProvider) {
                        ForEach(LLMProviderType.allCases, id: \.rawValue) { type in
                            Text(type.displayName).tag(type.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            if LLMProviderType(rawValue: viewModel.llmProvider) == .bedrock {
                bedrockConfig
            } else if LLMProviderType(rawValue: viewModel.llmProvider) == .openai {
                openAIConfig
            }

            correctionPromptCard
        }
    }

    private var bedrockConfig: some View {
        VStack(spacing: 22) {
            SettingsGroup(title: "Authentication") {
                SettingsField(label: "Auth mode") {
                    Picker("", selection: $viewModel.bedrockAuthMode) {
                        Text("AWS Profile").tag("profile")
                        Text("Access Key").tag("accessKey")
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                if viewModel.bedrockAuthMode == "profile" {
                    SettingsFieldDivider()
                    SettingsField(label: "Profile name") {
                        DesignTextField(text: $viewModel.bedrockProfileName, prompt: "default")
                    }
                } else {
                    SettingsFieldDivider()
                    SettingsField(label: "Access key") {
                        DesignTextField(text: $viewModel.bedrockAccessKey, prompt: "AKIA…")
                    }
                    SettingsFieldDivider()
                    SettingsField(label: "Secret key") {
                        DesignSecureField(text: $viewModel.bedrockSecretKey, prompt: "Secret access key")
                    }
                }
            }
            SettingsGroup(title: "Configuration") {
                SettingsField(label: "Region") {
                    DesignTextField(text: $viewModel.bedrockRegion, prompt: "us-east-1")
                }
                SettingsFieldDivider()
                SettingsField(label: "Model ID") {
                    DesignTextField(text: $viewModel.bedrockModelId, prompt: "anthropic.claude-3-haiku…")
                }
            }
        }
    }

    private var openAIConfig: some View {
        SettingsGroup(title: "OpenAI Configuration") {
            SettingsField(label: "Presets") {
                HStack(spacing: 6) {
                    presetButton("OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini")
                    presetButton("Ollama", baseURL: "http://localhost:11434/v1", model: "llama3.2", clearAPIKey: true)
                    presetButton("LM Studio", baseURL: "http://localhost:1234/v1", model: "local-model", clearAPIKey: true)
                }
            }
            SettingsFieldDivider()
            SettingsField(label: "API Endpoint") {
                DesignTextField(text: $viewModel.openAIBaseURL, prompt: "https://api.openai.com/v1")
            }
            SettingsFieldDivider()
            SettingsField(label: "API Key") {
                DesignSecureField(text: $viewModel.openAIAPIKey, prompt: "Optional for local")
            }
            SettingsFieldDivider()
            SettingsField(label: "Model") {
                DesignTextField(text: $viewModel.openAIModel, prompt: "gpt-4o-mini")
            }
            SettingsFieldDivider()
            SettingsField(label: "Custom Headers") {
                DesignTextField(text: $viewModel.openAICustomHeaders, prompt: "{\"key\":\"value\"}")
            }
        }
    }

    private func presetButton(_ name: String, baseURL: String, model: String, clearAPIKey: Bool = false) -> some View {
        Button(name) {
            viewModel.openAIBaseURL = baseURL
            viewModel.openAIModel = model
            if clearAPIKey { viewModel.openAIAPIKey = "" }
        }
        .controlSize(.small)
    }

    private var correctionPromptCard: some View {
        SettingsGroup(title: "Correction Prompt") {
            SettingsField(label: "Prompt mode") {
                Picker("", selection: $viewModel.useCustomPrompt) {
                    Text("Default").tag(false)
                    Text("Custom").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            SettingsFieldDivider()
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.useCustomPrompt {
                    Text("Editable · preserved across updates")
                        .font(.system(size: 11)).foregroundStyle(DesignTokens.txt3)
                    TextEditor(text: $viewModel.customPromptText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 140)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(DesignTokens.surface3))
                } else {
                    Text("Built-in prompt, updated with new app versions")
                        .font(.system(size: 11)).foregroundStyle(DesignTokens.txt3)
                    ScrollView {
                        Text(LLMCorrectionService.defaultCorrectionPrompt)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(DesignTokens.txt2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120, maxHeight: 200)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DesignTokens.surface3))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }

    private func directoryDisplay(_ url: URL) -> String {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let short = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        return String(short)
    }
}

// MARK: - Reusable components

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.07 * 10.5)
                .foregroundStyle(DesignTokens.txt3)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(DesignTokens.surface)
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(DesignTokens.line, lineWidth: 1))
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsField<Control: View>: View {
    let label: String
    var detail: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.txt)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DesignTokens.txt3)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

struct SettingsFieldDivider: View {
    var body: some View {
        Rectangle().fill(DesignTokens.line2).frame(height: 1).padding(.leading, 16)
    }
}

struct DesignToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(DesignTokens.acc)
    }
}

/// Rounded surface2 fill + hairline stroke shared by the settings text fields and
/// the Open-Folder button (was inlined verbatim at four sites).
private extension View {
    func fieldSurface() -> some View {
        background(
            RoundedRectangle(cornerRadius: 8).fill(DesignTokens.surface2)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DesignTokens.line, lineWidth: 1))
        )
    }
}

struct DesignTextField: View {
    @Binding var text: String
    var prompt: String
    var secure = false
    var body: some View {
        Group {
            if secure {
                SecureField("", text: $text, prompt: Text(prompt))
            } else {
                TextField("", text: $text, prompt: Text(prompt))
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12.5, design: .monospaced))
        .frame(width: 210)
        .padding(.horizontal, 11).padding(.vertical, 7)
        .fieldSurface()
    }
}

struct DesignSecureField: View {
    @Binding var text: String
    var prompt: String
    var body: some View {
        DesignTextField(text: $text, prompt: prompt, secure: true)
    }
}

struct OpenFolderButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "folder").font(.system(size: 11))
                Text("Open Folder").font(.system(size: 12.5))
            }
            .foregroundStyle(DesignTokens.txt)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .fieldSurface()
        }
        .buttonStyle(.plain)
    }
}

private struct ModelRow: View {
    let model: MLXModel
    let isSelected: Bool
    let onSelect: () -> Void
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().stroke(isSelected ? DesignTokens.acc : DesignTokens.line, lineWidth: 1.5)
                if isSelected { Circle().fill(DesignTokens.acc).frame(width: 8, height: 8) }
            }
            .frame(width: 16, height: 16)
            Text(model.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignTokens.txt)
            Spacer(minLength: 8)
            Text(model.size)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(DesignTokens.txt3)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(DesignTokens.surface3))
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(DesignTokens.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { if !isSelected { onSelect() } }
    }
}

private struct PermissionsCard: View {
    @StateObject private var permissions = PermissionsManager()

    var body: some View {
        SettingsGroup(title: "Permissions") {
            permRow("Microphone", granted: permissions.isMicrophonePermissionGranted, action: nil)
            SettingsFieldDivider()
            permRow("Accessibility", granted: permissions.isAccessibilityPermissionGranted, action: nil)
            SettingsFieldDivider()
            permRow("Screen Recording", granted: permissions.isScreenRecordingPermissionGranted) {
                permissions.openSystemPreferences(for: .screenRecording)
            }
        }
    }

    private func permRow(_ label: String, granted: Bool, action: (() -> Void)?) -> some View {
        SettingsField(label: label) {
            HStack(spacing: 8) {
                if !granted, let action {
                    Button("Open Settings", action: action).controlSize(.small)
                }
                HStack(spacing: 6) {
                    Image(systemName: granted ? "checkmark" : "xmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text(granted ? "Granted" : "Not Granted")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(granted ? DesignTokens.green : DesignTokens.red)
            }
        }
    }
}
