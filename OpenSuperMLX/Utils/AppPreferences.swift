import Foundation

@propertyWrapper
struct UserDefault<T> {
    let key: String
    let defaultValue: T
    
    var wrappedValue: T {
        get { AppPreferences.store.object(forKey: key) as? T ?? defaultValue }
        set { AppPreferences.store.set(newValue, forKey: key) }
    }
}

@propertyWrapper
struct OptionalUserDefault<T> {
    let key: String
    
    var wrappedValue: T? {
        get { AppPreferences.store.object(forKey: key) as? T }
        set { AppPreferences.store.set(newValue, forKey: key) }
    }
}

final class AppPreferences {
    static let shared = AppPreferences()
    
    /// The UserDefaults backing store for all preference properties.
    /// Override in test setUp; reset to `.standard` in tearDown.
    static var store: UserDefaults = .standard
    
    private init() {
        migrateOldPreferences()
    }
    
    private func migrateOldPreferences() {
        Self.migrateOldPreferences(defaults: .standard)
    }
    
    static func migrateOldPreferences(defaults: UserDefaults) {
        if let oldLanguage = defaults.string(forKey: "whisperLanguage"),
           defaults.string(forKey: "mlxLanguage") == nil {
            defaults.set(oldLanguage, forKey: "mlxLanguage")
        }
        
        migrateCorrectionPrompt(defaults: defaults)
        
        if !defaults.bool(forKey: "llmMigrationCompleted") {
            if defaults.object(forKey: "bedrockEnabled") != nil {
                let wasEnabled = defaults.bool(forKey: "bedrockEnabled")
                if defaults.object(forKey: "llmCorrectionEnabled") == nil {
                    defaults.set(wasEnabled, forKey: "llmCorrectionEnabled")
                }
                if wasEnabled, defaults.string(forKey: "llmProvider") == nil {
                    defaults.set("bedrock", forKey: "llmProvider")
                }
            }
            defaults.set(true, forKey: "llmMigrationCompleted")
        }
        
        defaults.removeObject(forKey: "selectedEngine")
        defaults.removeObject(forKey: "selectedWhisperModelPath")
        defaults.removeObject(forKey: "fluidAudioModelVersion")
        defaults.removeObject(forKey: "whisperLanguage")
        defaults.removeObject(forKey: "noSpeechThreshold")
        defaults.removeObject(forKey: "initialPrompt")
        defaults.removeObject(forKey: "useBeamSearch")
        defaults.removeObject(forKey: "beamSize")
        defaults.removeObject(forKey: "modifierOnlyHotkey")
        defaults.removeObject(forKey: "suppressBlankAudio")
        defaults.removeObject(forKey: "useChineseITN")
        defaults.removeObject(forKey: "useEnglishITN")
    }
    
    static func migrateCorrectionPrompt(defaults: UserDefaults) {
        if let oldPrompt = defaults.string(forKey: "bedrockCorrectionPrompt") {
            if oldPrompt != LLMCorrectionService.defaultCorrectionPrompt {
                defaults.set(oldPrompt, forKey: "customCorrectionPrompt")
                defaults.set(true, forKey: "useCustomCorrectionPrompt")
            }
            defaults.removeObject(forKey: "bedrockCorrectionPrompt")
        }
    }
    
    @UserDefault(key: "selectedMLXModel", defaultValue: "mlx-community/Qwen3-ASR-1.7B-8bit")
    var selectedMLXModel: String
    
    @UserDefault(key: "mlxLanguage", defaultValue: "auto")
    var mlxLanguage: String
    
    // Transcription settings
    @UserDefault(key: "translateToEnglish", defaultValue: false)
    var translateToEnglish: Bool
    
    @UserDefault(key: "temperature", defaultValue: 0.0)
    var temperature: Double
    
    @UserDefault(key: "debugMode", defaultValue: false)
    var debugMode: Bool
    
    @UserDefault(key: "playSoundOnRecordStart", defaultValue: false)
    var playSoundOnRecordStart: Bool
    
    @UserDefault(key: "hasCompletedOnboarding", defaultValue: false)
    var hasCompletedOnboarding: Bool
    
    @UserDefault(key: "useAsianAutocorrect", defaultValue: true)
    var useAsianAutocorrect: Bool
    
    @OptionalUserDefault(key: "selectedMicrophoneData")
    var selectedMicrophoneData: Data?
    
    // MARK: - Bedrock LLM
    
    @UserDefault(key: "bedrockEnabled", defaultValue: false)
    var bedrockEnabled: Bool
    
    @UserDefault(key: "bedrockAuthMode", defaultValue: "profile")
    var bedrockAuthMode: String
    
    @UserDefault(key: "bedrockProfileName", defaultValue: "default")
    var bedrockProfileName: String
    
    @UserDefault(key: "bedrockAccessKey", defaultValue: "")
    var bedrockAccessKey: String
    
    @UserDefault(key: "bedrockSecretKey", defaultValue: "")
    var bedrockSecretKey: String
    
    @UserDefault(key: "bedrockRegion", defaultValue: "us-east-1")
    var bedrockRegion: String
    
    @UserDefault(key: "bedrockModelId", defaultValue: "anthropic.claude-3-haiku-20240307-v1:0")
    var bedrockModelId: String
    
    // MARK: - Correction Prompt
    
    @UserDefault(key: "useCustomCorrectionPrompt", defaultValue: false)
    var useCustomCorrectionPrompt: Bool
    
    @OptionalUserDefault(key: "customCorrectionPrompt")
    var customCorrectionPrompt: String?
    
    var effectiveCorrectionPrompt: String {
        if useCustomCorrectionPrompt, let custom = customCorrectionPrompt, !custom.isEmpty {
            return custom
        }
        return LLMCorrectionService.defaultCorrectionPrompt
    }

    @UserDefault(key: "useStreamingTranscription", defaultValue: true)
    var useStreamingTranscription: Bool

    // MARK: - LLM Provider Selection

    @UserDefault(key: "llmProvider", defaultValue: "bedrock")
    var llmProvider: String

    @UserDefault(key: "llmCorrectionEnabled", defaultValue: false)
    var llmCorrectionEnabled: Bool

    // MARK: - OpenAI-Compatible LLM

    @UserDefault(key: "openAIBaseURL", defaultValue: "https://api.openai.com/v1")
    var openAIBaseURL: String

    @UserDefault(key: "openAIAPIKey", defaultValue: "")
    var openAIAPIKey: String

    @UserDefault(key: "openAIModel", defaultValue: "gpt-4o-mini")
    var openAIModel: String

    @UserDefault(key: "openAICustomHeaders", defaultValue: "")
    var openAICustomHeaders: String

    // MARK: - Audio Source

    @UserDefault(key: "audioSourceMode", defaultValue: "auto")
    var audioSourceMode: String
}
