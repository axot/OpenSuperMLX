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
    
    @Published var llmProvider: String {
        didSet { AppPreferences.shared.llmProvider = llmProvider }
    }
    
    @Published var llmCorrectionEnabled: Bool {
        didSet { AppPreferences.shared.llmCorrectionEnabled = llmCorrectionEnabled }
    }
    
    @Published var llmCorrectionPrompt: String {
        didSet { AppPreferences.shared.llmCorrectionPrompt = llmCorrectionPrompt }
    }
    
    @Published var openAIBaseURL: String {
        didSet { AppPreferences.shared.openAIBaseURL = openAIBaseURL }
    }
    
    @Published var openAIAPIKey: String {
        didSet { AppPreferences.shared.openAIAPIKey = openAIAPIKey }
    }
    
    @Published var openAIModel: String {
        didSet { AppPreferences.shared.openAIModel = openAIModel }
    }
    
    @Published var openAICustomHeaders: String {
        didSet { AppPreferences.shared.openAICustomHeaders = openAICustomHeaders }
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
        self.temperature = prefs.temperature
        self.debugMode = prefs.debugMode
        self.playSoundOnRecordStart = prefs.playSoundOnRecordStart
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.bedrockEnabled = prefs.bedrockEnabled
        self.bedrockAuthMode = prefs.bedrockAuthMode
        self.bedrockProfileName = prefs.bedrockProfileName
        self.bedrockAccessKey = prefs.bedrockAccessKey
        self.bedrockSecretKey = prefs.bedrockSecretKey
        self.bedrockRegion = prefs.bedrockRegion
        self.bedrockModelId = prefs.bedrockModelId
        self.bedrockCorrectionPrompt = prefs.bedrockCorrectionPrompt
        self.llmProvider = prefs.llmProvider
        self.llmCorrectionEnabled = prefs.llmCorrectionEnabled
        self.llmCorrectionPrompt = prefs.llmCorrectionPrompt
        self.openAIBaseURL = prefs.openAIBaseURL
        self.openAIAPIKey = prefs.openAIAPIKey
        self.openAIModel = prefs.openAIModel
        self.openAICustomHeaders = prefs.openAICustomHeaders
        self.useStreamingTranscription = prefs.useStreamingTranscription
    }
}

struct Settings {
    static let asianLanguages: Set<String> = ["zh", "ja", "ko"]
    
    var selectedLanguage: String
    var translateToEnglish: Bool
    var temperature: Double
    var useAsianAutocorrect: Bool
    var useStreamingTranscription: Bool
    
    var isAsianLanguage: Bool {
        Settings.asianLanguages.contains(selectedLanguage)
    }
    
    var shouldApplyAsianAutocorrect: Bool {
        isAsianLanguage && useAsianAutocorrect
    }
    
    var shouldApplyChineseITN: Bool {
        selectedLanguage == "zh" || selectedLanguage == "auto"
    }
    
    var shouldApplyEnglishITN: Bool {
        selectedLanguage == "en" || selectedLanguage == "auto"
    }
    
    init(
        selectedLanguage: String = AppPreferences.shared.mlxLanguage,
        translateToEnglish: Bool = AppPreferences.shared.translateToEnglish,
        temperature: Double = AppPreferences.shared.temperature,
        useAsianAutocorrect: Bool = AppPreferences.shared.useAsianAutocorrect,
        useStreamingTranscription: Bool = AppPreferences.shared.useStreamingTranscription
    ) {
        self.selectedLanguage = selectedLanguage
        self.translateToEnglish = translateToEnglish
        self.temperature = temperature
        self.useAsianAutocorrect = useAsianAutocorrect
        self.useStreamingTranscription = useStreamingTranscription
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
                                Text("Transcribe in real-time while recording")
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
                // Enable + Provider Picker
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("LLM Correction")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("Use an LLM to clean up transcription output")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $viewModel.llmCorrectionEnabled)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
                    }
                    
                    if viewModel.llmCorrectionEnabled {
                        Picker("Provider", selection: $viewModel.llmProvider) {
                            ForEach(LLMProviderType.allCases, id: \.rawValue) { type in
                                Text(type.displayName).tag(type.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Provider-Specific Configuration
                if viewModel.llmCorrectionEnabled {
                    if LLMProviderType(rawValue: viewModel.llmProvider) == .bedrock {
                        // Bedrock Authentication
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
                        
                        // Bedrock Configuration
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
                        
                    } else if LLMProviderType(rawValue: viewModel.llmProvider) == .openai {
                        // OpenAI-Compatible Configuration
                        VStack(alignment: .leading, spacing: 16) {
                            Text("OpenAI Configuration")
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            HStack(spacing: 8) {
                                presetButton("OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini")
                                presetButton("Ollama", baseURL: "http://localhost:11434/v1", model: "llama3.2", clearAPIKey: true)
                                presetButton("LM Studio", baseURL: "http://localhost:1234/v1", model: "local-model", clearAPIKey: true)
                                presetButton("OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-4o-mini")
                            }
                            
                            LabeledContent("API Endpoint") {
                                TextField("https://api.openai.com/v1", text: $viewModel.openAIBaseURL)
                                    .textFieldStyle(.roundedBorder)
                            }
                            
                            LabeledContent("API Key") {
                                SecureField("Optional for local models", text: $viewModel.openAIAPIKey)
                                    .textFieldStyle(.roundedBorder)
                            }
                            
                            LabeledContent("Model") {
                                TextField("gpt-4o-mini", text: $viewModel.openAIModel)
                                    .textFieldStyle(.roundedBorder)
                            }
                            
                            LabeledContent("Custom Headers") {
                                TextField("{\"key\": \"value\"}", text: $viewModel.openAICustomHeaders)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                            }
                            Text("Optional JSON headers for Azure, OpenRouter, etc.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.controlBackgroundColor).opacity(0.3))
                        .cornerRadius(12)
                    }
                    
                    // Correction Prompt (shared)
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Correction Prompt")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            Button("Reset to Default") {
                                viewModel.llmCorrectionPrompt = LLMCorrectionService.defaultCorrectionPrompt
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("System prompt sent to the LLM for transcription correction")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            TextEditor(text: $viewModel.llmCorrectionPrompt)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 80)
                                .padding(4)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(6)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
                }
            }
            .padding()
        }
    }
    
    private func presetButton(_ name: String, baseURL: String, model: String, clearAPIKey: Bool = false) -> some View {
        Button(name) {
            viewModel.openAIBaseURL = baseURL
            viewModel.openAIModel = model
            if clearAPIKey {
                viewModel.openAIAPIKey = ""
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    
    private var shortcutSettings: some View {
        Form {
            VStack(spacing: 20) {
                // Recording Trigger
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recording Trigger")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
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
                        
                        HStack {
                            Text("Record with LLM")
                                .font(.subheadline)
                            Spacer()
                            KeyboardShortcuts.Recorder("", name: .toggleRecordWithLLM)
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

