import Foundation
import SwiftData
import os

struct SwiftDataContainer {

    private static let log = Logger(subsystem: "app.lumivault", category: "store")

    /// Sidecars SQLite keeps beside the store. They must travel with it when the
    /// store is quarantined — leaving a `-wal` behind lets SQLite re-associate it
    /// with the newly created store and reintroduce the very state we moved aside.
    private static let storeSidecarSuffixes = ["", "-wal", "-shm"]

    /// True when the last `create` could not open the existing store and rebuilt
    /// from scratch. The catalog is the source of truth and `SyncCoordinator`
    /// rehydrates an empty store on launch, so recovery is automatic — but the
    /// app can read this to tell the user why local-only state (thumbnail status,
    /// last-verified dates, perceptual hashes) reset.
    private(set) nonisolated(unsafe) static var didRecoverFromUnopenableStore = false

    /// Where the quarantined store was moved, when recovery happened.
    private(set) nonisolated(unsafe) static var quarantinedStoreURL: URL?

    static var defaultStoreURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("LumiVault.store")
    }

    static func create() -> ModelContainer {
        create(storeURL: defaultStoreURL)
    }

    /// - Parameter storeURL: on-disk location of the store. Parameterised so the
    ///   recovery path can be tested without pointing at the real store — the app's
    ///   single Application Support store is not something a test may touch.
    static func create(storeURL: URL) -> ModelContainer {
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

        let config = ModelConfiguration("LumiVault", schema: schema, url: storeURL)

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // An unopenable store used to be a `fatalError`, which means the app
            // terminates on launch with no way back. That is the wrong trade for
            // this app: SwiftData here is a derived index, and `catalog.json` —
            // mirrored to every volume, iCloud and B2 — is the source of truth.
            // Refusing to launch protects nothing and strands the user.
            //
            // It is also reachable. A lightweight migration interrupted partway
            // (crash, force quit, power loss) leaves the store with the new
            // schema's tables but the old model metadata recorded, so every
            // subsequent open re-attempts the migration and fails on the objects
            // it already created — permanently. Observed exactly that after an
            // interrupted to-many migration:
            //   "Cannot migrate store in-place: 'table Z_1IMAGES already exists'"
            //
            // So: move the unopenable store aside and start a clean one.
            // `SyncCoordinator.setup` rehydrates from the catalog on launch, so
            // albums and images come back on their own. Only local-only fields
            // (thumbnail state, lastVerifiedAt, perceptualHash) are lost, and
            // those regenerate.
            log.error("Store at \(storeURL.path, privacy: .public) could not be opened: \(error, privacy: .public)")

            do {
                let quarantine = try quarantineStore(at: storeURL)
                quarantinedStoreURL = quarantine
                didRecoverFromUnopenableStore = true
                log.warning("Quarantined the unopenable store at \(quarantine.path, privacy: .public); rebuilding from catalog.json")
            } catch {
                // Could not move it — fall through and let the retry decide. If the
                // store is still in place the retry fails too and we stop, which is
                // the honest outcome rather than looping.
                log.error("Could not quarantine the store: \(error, privacy: .public)")
            }

            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                // A fresh store in a writable directory failing is not a recoverable
                // condition — the disk is full, the container is unwritable, or the
                // schema itself is invalid. Nothing left to fall back to.
                fatalError("Failed to create ModelContainer even after recovery: \(error)")
            }
        }
    }

    /// Move the store and its SQLite sidecars to a timestamped sibling directory.
    ///
    /// Moved rather than deleted: it may still hold recoverable local-only state,
    /// and silently destroying a user's database on a failed open is a worse
    /// default than leaving a copy they can hand to support.
    @discardableResult
    private static func quarantineStore(at storeURL: URL) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let directory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("Unopenable-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for suffix in storeSidecarSuffixes {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.moveItem(
                at: source,
                to: directory.appendingPathComponent(source.lastPathComponent)
            )
        }
        return directory
    }
}
