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

    /// Via `Constants.Paths.applicationSupportURL`, not `URL.applicationSupportDirectory`,
    /// so a test process cannot open the real store. It was previously isolated only by
    /// accident — an unsandboxed test process resolves Application Support outside the
    /// sandboxed app's container — which is exactly the kind of accidental isolation the
    /// sandbox work replaces with a guarantee.
    static var defaultStoreURL: URL {
        Constants.Paths.applicationSupportURL.appendingPathComponent("LumiVault.store")
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

            // Try once more before doing anything irreversible-looking. Not every
            // failed open means a corrupt store — a second copy of the app still
            // holding it, or a volume that has not finished mounting, fails once and
            // succeeds immediately after. Quarantining on the first failure costs the
            // user every VolumeRecord (and its security-scoped bookmark, so every
            // external drive needs re-authorising), every storageLocation, and all
            // thumbnail state — none of which hydration restores.
            if let container = try? ModelContainer(for: schema, configurations: [config]) {
                log.notice("Store opened on retry; no recovery needed")
                return container
            }

            do {
                if let quarantine = try quarantineStore(at: storeURL) {
                    quarantinedStoreURL = quarantine
                    didRecoverFromUnopenableStore = true
                    log.warning("Quarantined the unopenable store at \(quarantine.path, privacy: .public); rebuilding from catalog.json")
                } else {
                    // Nothing on disk to move, so the failure is about the schema or
                    // the directory, not the store file. Saying "recovered" here would
                    // be a lie, and it used to leave an empty `Unopenable-*` directory
                    // behind on every launch attempt.
                    log.error("No store file to quarantine; the open failure is not about the store contents")
                }
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
    ///
    /// - Returns: the quarantine directory, or `nil` when there was no store on disk
    ///   to move — an open that fails with no store file is about the schema or the
    ///   directory, and reporting that as a recovery both misleads the caller and
    ///   litters Application Support with empty `Unopenable-*` directories.
    /// Test seam. The only way to make `ModelContainer` fail with no store present is
    /// to break the schema, which a test cannot do to the app's real models, so the
    /// "nothing to move" and collision cases are exercised on the function directly.
    static func quarantineStoreForTesting(at storeURL: URL) throws -> URL? {
        try quarantineStore(at: storeURL)
    }

    private static func quarantineStore(at storeURL: URL) throws -> URL? {
        let sources = storeSidecarSuffixes
            .map { URL(fileURLWithPath: storeURL.path + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !sources.isEmpty else { return nil }

        // Second-resolution timestamps collide when two opens fail inside the same
        // second: `createDirectory` succeeds on the existing directory and the move
        // then throws on an existing destination, so the second quarantine silently
        // failed and left the bad store in place.
        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let unique = UUID().uuidString.prefix(8)
        let directory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("Unopenable-\(stamp)-\(unique)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for source in sources {
            try FileManager.default.moveItem(
                at: source,
                to: directory.appendingPathComponent(source.lastPathComponent)
            )
        }
        return directory
    }
}
