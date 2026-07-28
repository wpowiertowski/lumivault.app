import Foundation
import SwiftData

struct SwiftDataContainer {
    static func create() -> ModelContainer {
        let schema = Schema([
            ImageRecord.self,
            AlbumRecord.self,
            VolumeRecord.self
        ])
        // Under UI test, keep the store in memory. The app otherwise opens the one
        // real store in Application Support, which is both a hazard (a UI test that
        // imports would write into the developer's actual library) and the reason
        // the existing UI tests are order- and history-dependent: they assert
        // against whatever albums happen to already exist. A fresh store per launch
        // makes them deterministic.
        if Constants.Paths.uiTestLibraryOverride != nil {
            do {
                return try ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
                )
            } catch {
                fatalError("Failed to create in-memory ModelContainer: \(error)")
            }
        }

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
