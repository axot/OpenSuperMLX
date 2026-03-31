import Foundation

@propertyWrapper
struct UserDefault<T> {
    let key: String
    let defaultValue: T
    
    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@propertyWrapper
struct OptionalUserDefault<T> {
    let key: String
    
    var wrappedValue: T? {
        get { UserDefaults.standard.object(forKey: key) as? T }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

final class AppPreferences {
    static let shared = AppPreferences()
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
            if oldPrompt != BedrockService.defaultCorrectionPrompt {
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
    
    @UserDefault(key: "useCustomCorrectionPrompt", defaultValue: false)
    var useCustomCorrectionPrompt: Bool
    
    @OptionalUserDefault(key: "customCorrectionPrompt")
    var customCorrectionPrompt: String?
    
    var effectiveCorrectionPrompt: String {
        if useCustomCorrectionPrompt, let custom = customCorrectionPrompt, !custom.isEmpty {
            return custom
        }
        return BedrockService.defaultCorrectionPrompt
    }

    @UserDefault(key: "useStreamingTranscription", defaultValue: true)
    var useStreamingTranscription: Bool
}
