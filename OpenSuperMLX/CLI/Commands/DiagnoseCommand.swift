// DiagnoseCommand.swift
// OpenSuperMLX

import ApplicationServices
import AVFoundation
import Foundation

import ArgumentParser

// MARK: - Result Types

struct DiagnoseResult: Encodable {
    let macosVersion: String
    let chipModel: String
    let availableMemoryGB: Double
    let installedModels: [String]
    let currentMicrophone: String?
    let permissions: PermissionStatus
    let settings: SettingsSummary
    let appVersion: String?

    enum CodingKeys: String, CodingKey {
        case macosVersion = "macos_version"
        case chipModel = "chip_model"
        case availableMemoryGB = "available_memory_gb"
        case installedModels = "installed_models"
        case currentMicrophone = "current_microphone"
        case permissions, settings
        case appVersion = "app_version"
    }

    struct PermissionStatus: Encodable {
        let microphone: String
        let accessibility: String
    }

    struct SettingsSummary: Encodable {
        let model: String
        let neuralEngineAudioTower: Bool
        let language: String
        let streaming: Bool
        let llmCorrectionEnabled: Bool

        enum CodingKeys: String, CodingKey {
            case model, language, streaming
            case neuralEngineAudioTower = "neural_engine_audio_tower"
            case llmCorrectionEnabled = "llm_correction_enabled"
        }
    }
}

// MARK: - Command

struct DiagnoseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnose",
        abstract: "Collect environment snapshot for diagnostics"
    )

    @OptionGroup var globalOptions: GlobalOptions

    func run() throws {
        let json = globalOptions.json
        runAsync {
            let result = DiagnoseCommand.collectDiagnostics()
            CLIOutput.printSuccess(command: "diagnose", data: result, json: json)
        }
    }

    // MARK: - Data Collection

    static func collectDiagnostics() -> DiagnoseResult {
        DiagnoseResult(
            macosVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            chipModel: readChipModel(),
            availableMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024),
            installedModels: listInstalledModels(),
            currentMicrophone: nil,
            permissions: DiagnoseResult.PermissionStatus(
                microphone: microphoneAuthStatus(),
                accessibility: accessibilityStatus()
            ),
            settings: DiagnoseResult.SettingsSummary(
                model: MLXModelManager.model.repoID,
                neuralEngineAudioTower: AppPreferences.shared.useNeuralEngineAudioTower,
                language: AppPreferences.store.string(forKey: "mlxLanguage") ?? "auto",
                streaming: AppPreferences.store.object(forKey: "useStreamingTranscription") != nil
                    ? AppPreferences.store.bool(forKey: "useStreamingTranscription")
                    : true,
                llmCorrectionEnabled: AppPreferences.store.bool(forKey: "llmCorrectionEnabled")
            ),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
    }

    // MARK: - Helpers

    private static func readChipModel() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    static func listInstalledModels(in modelsDirectory: URL = MLXModelManager.modelsDirectory) -> [String] {
        var installed: [String] = []
        let modelID = MLXModelManager.model.repoID
        let modelDirectory = modelsDirectory
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(modelID.replacingOccurrences(of: "/", with: "_"))
        if hasWeights(modelDirectory) {
            installed.append(modelID)
        }
        let encoder = CoreMLAudioTowerAssets.installDirectory(in: modelsDirectory)
            .appendingPathComponent(CoreMLAudioTowerAssets.modelName)
        if CoreMLAudioTowerAssets.isInstalled(at: encoder) {
            installed.append(CoreMLAudioTowerAssets.repositoryID)
        }
        return installed
    }

    private static func hasWeights(_ directory: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.contains { file in
            file.pathExtension == "safetensors"
                && ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
        }
    }

    private static func microphoneAuthStatus() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    private static func accessibilityStatus() -> String {
        #if DEBUG
        return "granted"
        #else
        return AXIsProcessTrusted() ? "granted" : "denied"
        #endif
    }
}
