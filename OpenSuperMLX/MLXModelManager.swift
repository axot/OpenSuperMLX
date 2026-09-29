import Foundation

struct MLXModel: Identifiable, Equatable {
    let id: String
    let name: String
    let repoID: String
    let size: String
    let description: String
}

enum MLXModelManager {
    static let modelsDirectory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.axot.OpenSuperMLX")
            .appendingPathComponent("mlx-models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let model = MLXModel(
        id: "qwen3-asr-1.7b-5bit",
        name: "Qwen3-ASR-1.7B-5bit",
        repoID: "mlx-community/Qwen3-ASR-1.7B-5bit",
        size: "~1.8GB",
        description: "5-bit decoder with a full-precision audio encoder"
    )
}
