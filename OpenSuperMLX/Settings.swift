import AppKit
import Foundation
import KeyboardShortcuts
import SwiftUI

class SettingsViewModel: ObservableObject {
    @Published var selectedMLXModel: String {
        didSet {
            AppPreferences.shared.selectedMLXModel = selectedMLXModel
            Task { @MainActor in
                TranscriptionService.shared.reloadEngine()
            }
        }
    }
    
    @Published var selectedLanguage: String {
        didSet {
            AppPreferences.shared.mlxLanguage = selectedLanguage
            NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
        }
    }

    @Published var translateToEnglish: Bool {
        didSet {
            AppPreferences.shared.translateToEnglish = translateToEnglish
        }
    }

    @Published var suppressBlankAudio: Bool {
        didSet {
            AppPreferences.shared.suppressBlankAudio = suppressBlankAudio
        }
    }

    @Published var temperature: Double {
        didSet {
            AppPreferences.shared.temperature = temperature
        }
    }

    @Published var debugMode: Bool {
        didSet {
            AppPreferences.shared.debugMode = debugMode
        }
    }
    
    @Published var playSoundOnRecordStart: Bool {
        didSet {
            AppPreferences.shared.playSoundOnRecordStart = playSoundOnRecordStart
        }
    }
    
    @Published var useAsianAutocorrect: Bool {
        didSet {
            AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect
        }
    }
    
    @Published var modifierOnlyHotkey: ModifierKey {
        didSet {
            AppPreferences.shared.modifierOnlyHotkey = modifierOnlyHotkey.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }
    
    @Published var holdToRecord: Bool {
        didSet {
            AppPreferences.shared.holdToRecord = holdToRecord
        }
    }
    
    @Published var bedrockEnabled: Bool {
        didSet { AppPreferences.shared.bedrockEnabled = bedrockEnabled }
    }
    
    @Published var bedrockAuthMode: String {
        didSet { AppPreferences.shared.bedrockAuthMode = bedrockAuthMode }
    }
    
    @Published var bedrockProfileName: String {
        didSet { AppPreferences.shared.bedrockProfileName = bedrockProfileName }
    }
    
    @Published var bedrockAccessKey: String {
        didSet { AppPreferences.shared.bedrockAccessKey = bedrockAccessKey }
    }
    
    @Published var bedrockSecretKey: String {
        didSet { AppPreferences.shared.bedrockSecretKey = bedrockSecretKey }
    }
    
    @Published var bedrockRegion: String {
        didSet { AppPreferences.shared.bedrockRegion = bedrockRegion }
    }
    
    @Published var bedrockModelId: String {
        didSet { AppPreferences.shared.bedrockModelId = bedrockModelId }
    }
    
    @Published var bedrockCorrectionPrompt: String {
        didSet { AppPreferences.shared.bedrockCorrectionPrompt = bedrockCorrectionPrompt }
    }

    @Published var useStreamingTranscription: Bool {
        didSet {
            AppPreferences.shared.useStreamingTranscription = useStreamingTranscription
        }
    }
    
    init() {
        let prefs = AppPreferences.shared
        self.selectedMLXModel = prefs.selectedMLXModel
        self.selectedLanguage = prefs.mlxLanguage
        self.translateToEnglish = prefs.translateToEnglish
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.temperature = prefs.temperature
        self.debugMode = prefs.debugMode
        self.playSoundOnRecordStart = prefs.playSoundOnRecordStart
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.modifierOnlyHotkey = ModifierKey(rawValue: prefs.modifierOnlyHotkey) ?? .none
        self.holdToRecord = prefs.holdToRecord
        self.bedrockEnabled = prefs.bedrockEnabled
        self.bedrockAuthMode = prefs.bedrockAuthMode
        self.bedrockProfileName = prefs.bedrockProfileName
        self.bedrockAccessKey = prefs.bedrockAccessKey
        self.bedrockSecretKey = prefs.bedrockSecretKey
        self.bedrockRegion = prefs.bedrockRegion
        self.bedrockModelId = prefs.bedrockModelId
        self.bedrockCorrectionPrompt = prefs.bedrockCorrectionPrompt
        self.useStreamingTranscription = prefs.useStreamingTranscription
    }
}

struct Settings {
    static let asianLanguages: Set<String> = ["zh", "ja", "ko"]
    
    var selectedLanguage: String
    var translateToEnglish: Bool
    var suppressBlankAudio: Bool
    var temperature: Double
    var useAsianAutocorrect: Bool
    var useStreamingTranscription: Bool
    
    var isAsianLanguage: Bool {
        Settings.asianLanguages.contains(selectedLanguage)
    }
    
    var shouldApplyAsianAutocorrect: Bool {
        isAsianLanguage && useAsianAutocorrect
    }
    
    init() {
        let prefs = AppPreferences.shared
        self.selectedLanguage = prefs.mlxLanguage
        self.translateToEnglish = prefs.translateToEnglish
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.temperature = prefs.temperature
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.useStreamingTranscription = prefs.useStreamingTranscription
    }
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var modelManager = MLXModelManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var isRecordingNewShortcut = false
    @State private var selectedTab = 0
    @State private var customModelInput = ""
    
    var body: some View {
        TabView(selection: $selectedTab) {
            shortcutSettings
                .tabItem {
                    Label("Shortcuts", systemImage: "command")
                }
                .tag(0)
            
            modelSettings
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }
                .tag(1)
            
            transcriptionSettings
                .tabItem {
                    Label("Transcription", systemImage: "text.bubble")
                }
                .tag(2)
            
            advancedSettings
                .tabItem {
                    Label("Advanced", systemImage: "gear")
                }
                .tag(3)
            
            llmSettings
                .tabItem {
                    Label("LLM", systemImage: "brain")
                }
                .tag(4)
        }
        .padding()
        .frame(width: 550)
        .background(Color(.windowBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                
                Spacer()
                
                Link(destination: URL(string: "https://github.com/axot/OpenSuperMLX")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "star")
                            .font(.system(size: 10))
                        Text("GitHub")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(.windowBackgroundColor))
        }
    }
    
    private var modelSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("MLX Speech Recognition Model")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("Select the model to use for transcription. Larger models are more accurate but use more memory.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    VStack(spacing: 12) {
                        ForEach(modelManager.availableModels) { model in
                            MLXModelPickerItemView(
                                model: model,
                                isSelected: viewModel.selectedMLXModel == model.repoID,
                                onSelect: {
                                    viewModel.selectedMLXModel = model.repoID
                                },
                                onDelete: model.isCustom ? {
                                    if viewModel.selectedMLXModel == model.repoID {
                                        viewModel.selectedMLXModel = MLXModelManager.builtInModels[1].repoID
                                    }
                                    modelManager.removeCustomModel(model)
                                } : nil
                            )
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Custom Model
                VStack(alignment: .leading, spacing: 16) {
                    Text("Custom Model")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add a model from HuggingFace by entering its repository ID or URL.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 8) {
                            TextField("e.g. mlx-community/Qwen3-ASR-1.7B-4bit", text: $customModelInput)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { addCustomModel() }
                            
                            Button(action: { addCustomModel() }) {
                                Text("Add")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(customModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Models Directory
                VStack(alignment: .leading, spacing: 16) {
                    Text("Models Directory")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Directory:")
                                .font(.subheadline)
                            Spacer()
                            Button(action: {
                                let dir = MLXModelManager.modelsDirectory.appendingPathComponent("mlx-audio")
                                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(dir)
                            }) {
                                Label("Open Folder", systemImage: "folder")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.borderless)
                        }
                        
                        Text(MLXModelManager.modelsDirectory.appendingPathComponent("mlx-audio").path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.textBackgroundColor).opacity(0.5))
                            .cornerRadius(6)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
            }
            .padding()
        }
    }
    
    private func addCustomModel() {
        modelManager.addCustomModel(repoID: customModelInput)
        customModelInput = ""
    }
    
    private var transcriptionSettings: some View {
        Form {
            VStack(spacing: 20) {
                // Language Settings
                VStack(alignment: .leading, spacing: 16) {
                    Text("Language Settings")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Transcription Language")
                            .font(.subheadline)
                        
                        Picker("Language", selection: $viewModel.selectedLanguage) {
                            ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                                Text(LanguageUtil.languageNames[code] ?? code)
                                    .tag(code)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.controlBackgroundColor))
                        .cornerRadius(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        HStack {
                            Text("Translate to English")
                                .font(.subheadline)
                            Spacer()
                            Toggle("", isOn: $viewModel.translateToEnglish)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                        .padding(.top, 4)
                        
                        if Settings.asianLanguages.contains(viewModel.selectedLanguage) {
                            HStack {
                                Text("Use Asian Autocorrect")
                                    .font(.subheadline)
                                Spacer()
                                Toggle("", isOn: $viewModel.useAsianAutocorrect)
                                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                    .labelsHidden()
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Output Options
                VStack(alignment: .leading, spacing: 16) {
                    Text("Output Options")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Suppress Blank Audio")
                                .font(.subheadline)
                            Spacer()
                            Toggle("", isOn: $viewModel.suppressBlankAudio)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Streaming
                VStack(alignment: .leading, spacing: 16) {
                    Text("Streaming")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Streaming Transcription")
                                    .font(.subheadline)
                                Text("Experimental: transcribe in real-time while recording")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.useStreamingTranscription)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Transcriptions Directory
                VStack(alignment: .leading, spacing: 16) {
                    Text("Transcriptions Directory")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Directory:")
                                .font(.subheadline)
                            Spacer()
                            Button(action: {
                                NSWorkspace.shared.open(Recording.recordingsDirectory)
                            }) {
                                Label("Open Folder", systemImage: "folder")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.borderless)
                            .help("Open transcriptions directory")
                        }
                        
                        Text(Recording.recordingsDirectory.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.textBackgroundColor).opacity(0.5))
                            .cornerRadius(6)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
            }
            .padding()
        }
    }
    
    private var advancedSettings: some View {
        Form {
            VStack(spacing: 20) {
                // Model Parameters
                VStack(alignment: .leading, spacing: 16) {
                    Text("Model Parameters")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Temperature:")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.2f", viewModel.temperature))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(value: $viewModel.temperature, in: 0.0...1.0, step: 0.1)
                                .help("Higher values make the output more random")
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Debug Options
                VStack(alignment: .leading, spacing: 16) {
                    Text("Debug Options")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    HStack {
                        Text("Debug Mode")
                            .font(.subheadline)
                        Spacer()
                        Toggle("", isOn: $viewModel.debugMode)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
                            .help("Enable additional logging and debugging information")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
            }
            .padding()
        }
    }
    
    // MARK: - LLM Settings
    
    private var llmSettings: some View {
        Form {
            VStack(spacing: 20) {
                // LLM Correction
                VStack(alignment: .leading, spacing: 16) {
                    Text("LLM Transcription Correction")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable LLM Correction")
                                .font(.subheadline)
                            Text("Experimental: Use AWS Bedrock to correct transcription output")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $viewModel.bedrockEnabled)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Authentication
                VStack(alignment: .leading, spacing: 16) {
                    Text("Authentication")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Auth Mode", selection: $viewModel.bedrockAuthMode) {
                            Text("AWS Profile").tag("profile")
                            Text("Access Key").tag("accessKey")
                        }
                        .pickerStyle(.segmented)
                        
                        if viewModel.bedrockAuthMode == "profile" {
                            HStack {
                                Text("Profile Name")
                                    .font(.subheadline)
                                    .frame(width: 100, alignment: .leading)
                                TextField("", text: $viewModel.bedrockProfileName, prompt: Text("default"))
                                    .textFieldStyle(.roundedBorder)
                            }
                        } else {
                            HStack {
                                Text("Access Key")
                                    .font(.subheadline)
                                    .frame(width: 100, alignment: .leading)
                                TextField("", text: $viewModel.bedrockAccessKey, prompt: Text("AKIA..."))
                                    .textFieldStyle(.roundedBorder)
                            }
                            
                            HStack {
                                Text("Secret Key")
                                    .font(.subheadline)
                                    .frame(width: 100, alignment: .leading)
                                SecureField("Secret access key", text: $viewModel.bedrockSecretKey)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Configuration
                VStack(alignment: .leading, spacing: 16) {
                    Text("Configuration")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Region")
                                .font(.subheadline)
                                .frame(width: 100, alignment: .leading)
                            TextField("", text: $viewModel.bedrockRegion, prompt: Text("us-east-1"))
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        HStack {
                            Text("Model ID")
                                .font(.subheadline)
                                .frame(width: 100, alignment: .leading)
                            TextField("", text: $viewModel.bedrockModelId, prompt: Text("anthropic.claude-3-haiku-20240307-v1:0"))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Correction Prompt
                VStack(alignment: .leading, spacing: 16) {
                    Text("Correction Prompt")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("System prompt sent to the LLM for transcription correction")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        TextEditor(text: $viewModel.bedrockCorrectionPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 80)
                            .padding(4)
                            .background(Color(.textBackgroundColor).opacity(0.5))
                            .cornerRadius(6)
                        
                        HStack {
                            Spacer()
                            Button("Reset to Default") {
                                viewModel.bedrockCorrectionPrompt = BedrockService.defaultCorrectionPrompt
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
            }
            .padding()
        }
    }
    
    private var useModifierKey: Bool {
        viewModel.modifierOnlyHotkey != .none
    }
    
    private var shortcutSettings: some View {
        Form {
            VStack(spacing: 20) {
                // Recording Trigger
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recording Trigger")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("", selection: Binding(
                            get: { useModifierKey },
                            set: { newValue in
                                if !newValue {
                                    viewModel.modifierOnlyHotkey = .none
                                } else if viewModel.modifierOnlyHotkey == .none {
                                    viewModel.modifierOnlyHotkey = .leftCommand
                                }
                            }
                        )) {
                            Text("Key Combination").tag(false)
                            Text("Single Modifier Key").tag(true)
                        }
                        .pickerStyle(.segmented)
                        
                        if useModifierKey {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Modifier Key")
                                        .font(.subheadline)
                                    Spacer()
                                    Picker("", selection: $viewModel.modifierOnlyHotkey) {
                                        ForEach(ModifierKey.allCases.filter { $0 != .none }) { key in
                                            Text(key.displayName).tag(key)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 200)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(8)
                                
                                Text("One-tap to toggle recording")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Shortcut")
                                        .font(.subheadline)
                                    Spacer()
                                    KeyboardShortcuts.Recorder("", name: .toggleRecord)
                                        .frame(width: 150)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(8)
                                
                                if isRecordingNewShortcut {
                                    Text("Press your new shortcut combination...")
                                        .foregroundColor(.secondary)
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Recording Behavior
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recording Behavior")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Hold to Record")
                                    .font(.subheadline)
                                Text("Hold the shortcut to record, release to stop")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.holdToRecord)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                        
                        HStack {
                            Text("Play sound when recording starts")
                                .font(.subheadline)
                            Spacer()
                            Toggle("", isOn: $viewModel.playSoundOnRecordStart)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                                .help("Play a notification sound when recording begins")
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
            }
            .padding()
        }
    }
}

struct MLXModelPickerItemView: View {
    let model: MLXModel
    let isSelected: Bool
    let onSelect: () -> Void
    var onDelete: (() -> Void)?
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text(model.size)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.controlBackgroundColor))
                        .cornerRadius(4)
                }
                
                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if let onDelete = onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red.opacity(0.7))
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .help("Remove custom model")
            }
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .imageScale(.large)
            } else {
                Button(action: onSelect) {
                    Text("Select")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(isSelected ? Color(.controlBackgroundColor).opacity(0.7) : Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isSelected {
                onSelect()
            }
        }
    }
}

