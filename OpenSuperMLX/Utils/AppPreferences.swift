import Foundation
import os.log

private let prefsLogger = Logger(subsystem: "OpenSuperMLX", category: "AppPreferences")

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
        migrateLLMOutputLimit(defaults: defaults)
        
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
    
    // Existing OpenAI-compatible setups ran with a 4096-token output cap; keep it so models with
    // smaller limits don't start rejecting requests after the new 16k default.
    static func migrateLLMOutputLimit(defaults: UserDefaults) {
        guard defaults.object(forKey: "openAIModel") != nil,
              defaults.object(forKey: "openAIMaxOutputTokens") == nil else { return }
        defaults.set(4096, forKey: "openAIMaxOutputTokens")
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
    
    @UserDefault(key: "useNeuralEngineAudioTower", defaultValue: true)
    var useNeuralEngineAudioTower: Bool
    
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

    @UserDefault(key: "bedrockThinkingEnabled", defaultValue: false)
    var bedrockThinkingEnabled: Bool

    @UserDefault(key: "bedrockThinkingEffort", defaultValue: LLMThinkingEffort.medium.rawValue)
    var bedrockThinkingEffort: String

    @UserDefault(key: "bedrockContextTokens", defaultValue: 200_000)
    var bedrockContextTokens: Int

    @UserDefault(key: "bedrockMaxOutputTokens", defaultValue: 4096)
    var bedrockMaxOutputTokens: Int
    
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

    @UserDefault(key: "openAIAPIProtocol", defaultValue: OpenAIAPIProtocol.chatCompletions.rawValue)
    var openAIAPIProtocol: String

    @UserDefault(key: "openAICustomHeaders", defaultValue: "")
    var openAICustomHeaders: String

    @UserDefault(key: "openAIExtraBody", defaultValue: "")
    var openAIExtraBody: String

    @UserDefault(key: "openAIThinkingEnabled", defaultValue: true)
    var openAIThinkingEnabled: Bool

    @UserDefault(key: "openAIThinkingEffort", defaultValue: LLMThinkingEffort.medium.rawValue)
    var openAIThinkingEffort: String

    @UserDefault(key: "openAIContextTokens", defaultValue: 131_072)
    var openAIContextTokens: Int

    @UserDefault(key: "openAIMaxOutputTokens", defaultValue: 16_384)
    var openAIMaxOutputTokens: Int

    func llmRequestOptions(for provider: LLMProviderType) -> LLMRequestOptions {
        let isOpenAI = provider == .openai
        return LLMRequestOptions(
            contextTokens: LLMRequestOptions.clampedTokens(isOpenAI ? openAIContextTokens : bedrockContextTokens),
            maxOutputTokens: LLMRequestOptions.clampedTokens(isOpenAI ? openAIMaxOutputTokens : bedrockMaxOutputTokens),
            thinkingEnabled: isOpenAI ? openAIThinkingEnabled : bedrockThinkingEnabled,
            thinkingEffort: LLMThinkingEffort(rawValue: isOpenAI ? openAIThinkingEffort : bedrockThinkingEffort) ?? .medium
        )
    }

    // MARK: - Audio Source

    @UserDefault(key: "speakerCaptureEnabled", defaultValue: false)
    var speakerCaptureEnabled: Bool

    // MARK: - Transcript MCP

    @UserDefault(key: "transcriptMCPEnabled", defaultValue: false)
    var transcriptMCPEnabled: Bool

    @UserDefault(key: "transcriptMCPPort", defaultValue: Int(TranscriptMCPHTTPServer.defaultPort))
    var transcriptMCPPort: Int

    // MARK: - Output Device Classifications

    @OptionalUserDefault(key: "outputDeviceClassifications")
    private var outputDeviceClassificationsData: Data?

    var outputDeviceClassifications: [String: ClassificationEntry] {
        get {
            guard let data = outputDeviceClassificationsData else { return [:] }
            do {
                return try JSONDecoder().decode([String: ClassificationEntry].self, from: data)
            } catch {
                prefsLogger.warning("Failed to decode outputDeviceClassifications, returning empty: \(error.localizedDescription, privacy: .public)")
                return [:]
            }
        }
        set {
            do {
                outputDeviceClassificationsData = try JSONEncoder().encode(newValue)
            } catch {
                prefsLogger.warning("Failed to encode outputDeviceClassifications: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
