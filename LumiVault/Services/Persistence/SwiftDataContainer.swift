import Foundation
import SwiftData

struct SwiftDataContainer {
    static func create() -> ModelContainer {
        let schema = Schema([
            ImageRecord.self,
            AlbumRecord.self,
            VolumeRecord.self
        ])
        let storeURL = URL.applicationSupportDirectory
            .appendingPathComponent("LumiVault.store")
        let config = ModelConfiguration(
            "LumiVault",
            schema: schema,
            url: storeURL
        )
        do {
            return try ModelContainer(
                for: schema,
                configurations: [config]
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }
}
