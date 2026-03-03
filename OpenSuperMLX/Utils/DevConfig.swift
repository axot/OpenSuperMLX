#if DEBUG
import Foundation

// OpenSuperMLX development configuration
struct DevConfig {
    static let shared = DevConfig()
    
    let forceShowOnboarding: Bool?
    
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
            return
        }
        
        forceShowOnboarding = json["forceShowOnboarding"] as? Bool
    }
}
#endif
