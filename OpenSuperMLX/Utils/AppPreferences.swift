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
        if let oldLanguage = UserDefaults.standard.string(forKey: "whisperLanguage"),
           UserDefaults.standard.string(forKey: "mlxLanguage") == nil {
            UserDefaults.standard.set(oldLanguage, forKey: "mlxLanguage")
        }
        
        UserDefaults.standard.removeObject(forKey: "selectedEngine")
        UserDefaults.standard.removeObject(forKey: "selectedWhisperModelPath")
        UserDefaults.standard.removeObject(forKey: "fluidAudioModelVersion")
        UserDefaults.standard.removeObject(forKey: "whisperLanguage")
        UserDefaults.standard.removeObject(forKey: "noSpeechThreshold")
        UserDefaults.standard.removeObject(forKey: "initialPrompt")
        UserDefaults.standard.removeObject(forKey: "useBeamSearch")
        UserDefaults.standard.removeObject(forKey: "beamSize")
        UserDefaults.standard.removeObject(forKey: "modifierOnlyHotkey")
    }
    
    @UserDefault(key: "selectedMLXModel", defaultValue: "mlx-community/Qwen3-ASR-1.7B-8bit")
    var selectedMLXModel: String
    
    @UserDefault(key: "mlxLanguage", defaultValue: "en")
    var mlxLanguage: String
    
    // Transcription settings
    @UserDefault(key: "translateToEnglish", defaultValue: false)
    var translateToEnglish: Bool
    
    @UserDefault(key: "suppressBlankAudio", defaultValue: true)
    var suppressBlankAudio: Bool
    
    @UserDefault(key: "showTimestamps", defaultValue: false)
    var showTimestamps: Bool
    
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
    
    @UserDefault(key: "bedrockCorrectionPrompt", defaultValue: BedrockService.defaultCorrectionPrompt)
    var bedrockCorrectionPrompt: String

    @UserDefault(key: "useStreamingTranscription", defaultValue: true)
    var useStreamingTranscription: Bool
}
