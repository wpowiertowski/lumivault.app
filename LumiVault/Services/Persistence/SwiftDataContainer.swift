import SwiftData

struct SwiftDataContainer {
    static func create() -> ModelContainer {
        let schema = Schema([
            ImageRecord.self,
            AlbumRecord.self,
            VolumeRecord.self
        ])
        let config = ModelConfiguration(
            "LumiVault",
            schema: schema
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
