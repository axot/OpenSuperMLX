import Foundation

struct MLXModel: Identifiable, Equatable {
    let id: String
    let name: String
    let repoID: String
    let size: String
    let description: String
}

enum MLXModelArchitecture: Equatable {
    case qwen3ASR
    case nemotronASR

    init?(modelType: String) {
        switch modelType {
        case "qwen3_asr": self = .qwen3ASR
        case "nemotron_asr": self = .nemotronASR
        default: return nil
        }
    }

    var supportsStreaming: Bool { self == .qwen3ASR }

    var summary: String {
        switch self {
        case .qwen3ASR: return "Qwen3-ASR · live streaming"
        case .nemotronASR: return "NVIDIA Nemotron RNN-T · transcribes when recording stops"
        }
    }
}

/// A model folder in the models directory, named like the Hugging Face repo with `/` → `_`.
struct LocalMLXModel: Identifiable, Equatable {
    let id: String
    let directory: URL
    let modelType: String?
    let sizeBytes: Int64

    var architecture: MLXModelArchitecture? { modelType.flatMap(MLXModelArchitecture.init(modelType:)) }
    var isSupported: Bool { architecture != nil }
    var supportsStreaming: Bool { architecture?.supportsStreaming ?? false }

    var name: String {
        guard let separator = id.firstIndex(of: "_") else { return id }
        return String(id[id.index(after: separator)...])
    }

    var repoID: String {
        guard let separator = id.firstIndex(of: "_") else { return id }
        return id.replacingCharacters(in: separator...separator, with: "/")
    }
}

enum MLXModelManager {
    static let modelsDirectory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.axot.OpenSuperMLX")
            .appendingPathComponent("mlx-models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var installedModelsDirectory: URL {
        modelsDirectory.appendingPathComponent("mlx-audio")
    }

    static let model = MLXModel(
        id: "qwen3-asr-1.7b-5bit",
        name: "Qwen3-ASR-1.7B-5bit",
        repoID: "mlx-community/Qwen3-ASR-1.7B-5bit",
        size: "~1.8GB",
        description: "5-bit decoder with a full-precision audio encoder"
    )

    static var builtInModelID: String {
        model.repoID.replacingOccurrences(of: "/", with: "_")
    }

    // MARK: - Discovery

    /// Model folders holding a `config.json` and non-empty safetensors weights, sorted by name.
    static func installedModels(in directory: URL = installedModelsDirectory) -> [LocalMLXModel] {
        let fileManager = FileManager.default
        let folders = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return folders.compactMap { folder -> LocalMLXModel? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let files = (try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            )) ?? []
            let sizes = files.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            let hasWeights = zip(files, sizes).contains { $0.pathExtension == "safetensors" && $1 > 0 }
            let configURL = folder.appendingPathComponent("config.json")
            guard hasWeights, let config = try? Data(contentsOf: configURL) else { return nil }
            let modelType = (try? JSONSerialization.jsonObject(with: config) as? [String: Any])?["model_type"] as? String
            return LocalMLXModel(
                id: folder.lastPathComponent,
                directory: folder,
                modelType: modelType,
                sizeBytes: sizes.reduce(0, +)
            )
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// Installed models plus the built-in model, which downloads on first use when missing.
    static func availableModels(in directory: URL = installedModelsDirectory) -> [LocalMLXModel] {
        let installed = installedModels(in: directory)
        if installed.contains(where: { $0.id == builtInModelID }) {
            return installed
        }
        return [builtInModel(in: directory)] + installed
    }

    // MARK: - Selection

    /// The model to load: the selected folder if it is installed and supported, else the built-in model.
    static func resolveSelectedModel(
        selectedID: String?,
        installed: [LocalMLXModel],
        directory: URL = installedModelsDirectory
    ) -> LocalMLXModel {
        installed.first { $0.id == selectedID && $0.isSupported }
            ?? installed.first { $0.id == builtInModelID }
            ?? builtInModel(in: directory)
    }

    static func selectedModel() -> LocalMLXModel {
        resolveSelectedModel(selectedID: AppPreferences.shared.selectedModel, installed: installedModels())
    }

    private static func builtInModel(in directory: URL) -> LocalMLXModel {
        LocalMLXModel(
            id: builtInModelID,
            directory: directory.appendingPathComponent(builtInModelID),
            modelType: "qwen3_asr",
            sizeBytes: 0
        )
    }
}
