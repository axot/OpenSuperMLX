import Foundation

struct MLXModel: Identifiable, Equatable {
    let id: String
    let name: String
    let repoID: String
    let size: String
    let description: String
    let isCustom: Bool
    
    init(id: String, name: String, repoID: String, size: String, description: String, isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.repoID = repoID
        self.size = size
        self.description = description
        self.isCustom = isCustom
    }
}

@MainActor
class MLXModelManager: ObservableObject {
    static let shared = MLXModelManager()
    
    static let modelsDirectory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.axot.OpenSuperMLX")
            .appendingPathComponent("mlx-models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    static let builtInModels: [MLXModel] = [
        MLXModel(
            id: "qwen3-asr-0.6b-4bit",
            name: "Qwen3-ASR-0.6B-4bit",
            repoID: "mlx-community/Qwen3-ASR-0.6B-4bit",
            size: "~400MB",
            description: "Smallest model, fastest inference"
        ),
        MLXModel(
            id: "qwen3-asr-1.7b-8bit",
            name: "Qwen3-ASR-1.7B-8bit",
            repoID: "mlx-community/Qwen3-ASR-1.7B-8bit",
            size: "~900MB",
            description: "Recommended model, balanced accuracy and speed"
        ),
        MLXModel(
            id: "qwen3-asr-1.7b-bf16",
            name: "Qwen3-ASR-1.7B-bf16",
            repoID: "mlx-community/Qwen3-ASR-1.7B-bf16",
            size: "~3.4GB",
            description: "Highest quality model, best accuracy but slower inference"
        )
    ]
    
    @Published var customModels: [MLXModel] = []
    
    var availableModels: [MLXModel] {
        Self.builtInModels + customModels
    }
    
    private init() {
        loadCustomModels()
    }
    
    func addCustomModel(repoID: String) {
        let trimmed = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let normalizedID = normalizeHuggingFaceInput(trimmed)
        
        guard !availableModels.contains(where: { $0.repoID == normalizedID }) else { return }
        
        customModels.append(makeCustomModel(repoID: normalizedID))
        saveCustomModels()
    }
    
    func removeCustomModel(_ model: MLXModel) {
        customModels.removeAll { $0.id == model.id }
        saveCustomModels()
    }
    
    private func makeCustomModel(repoID: String) -> MLXModel {
        let name = repoID.components(separatedBy: "/").last ?? repoID
        return MLXModel(
            id: "custom-\(name.lowercased())",
            name: name,
            repoID: repoID,
            size: "Custom",
            description: repoID,
            isCustom: true
        )
    }
    
    private func normalizeHuggingFaceInput(_ input: String) -> String {
        var result = input
        for prefix in ["https://huggingface.co/", "http://huggingface.co/"] {
            if result.hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count))
                break
            }
        }
        if result.hasSuffix("/") {
            result = String(result.dropLast())
        }
        return result
    }
    
    private func saveCustomModels() {
        let repoIDs = customModels.map { $0.repoID }
        UserDefaults.standard.set(repoIDs, forKey: "customMLXModels")
    }
    
    private func loadCustomModels() {
        guard let repoIDs = UserDefaults.standard.stringArray(forKey: "customMLXModels") else { return }
        customModels = repoIDs.map { makeCustomModel(repoID: $0) }
    }
}
