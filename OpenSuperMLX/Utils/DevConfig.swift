#if DEBUG
import Foundation

// OpenSuperMLX development configuration
struct DevConfig {
    static let shared = DevConfig()
    
    let forceShowOnboarding: Bool?
    let forceRecordingSaveFailure: Bool
    
    private init() {
        let filePath = (
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Utils
                .deletingLastPathComponent() // OpenSuperMLX
                .deletingLastPathComponent() // project root
                .appendingPathComponent("dev_config.json")
        ).path
        
        guard FileManager.default.fileExists(atPath: filePath),
              let data = FileManager.default.contents(atPath: filePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            forceShowOnboarding = nil
            forceRecordingSaveFailure = false
            return
        }
        
        forceShowOnboarding = json["forceShowOnboarding"] as? Bool
        forceRecordingSaveFailure = json["forceRecordingSaveFailure"] as? Bool ?? false
    }
}
#endif
