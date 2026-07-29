import Testing
import Foundation
import SwiftData
@testable import LumiVault

// MARK: - Unopenable-store recovery
//
// `SwiftDataContainer.create()` used to `fatalError` when the store would not
// open, which terminates the app on launch with no way back.
//
// That is reachable, not theoretical. A lightweight migration interrupted partway
// — crash, force quit, power loss — leaves the store carrying the new schema's
// tables while its metadata still records the old model. Every subsequent open
// re-attempts the migration and fails on the objects it already created:
//
//     Cannot migrate store in-place: 'table Z_1IMAGES already exists'
//
// That state was reached for real during development of the to-many album
// relationship, and the app could not be launched afterwards.
//
// SwiftData here is a derived index; `catalog.json` is the source of truth and is
// mirrored to every volume, iCloud and B2. `SyncCoordinator.setup` rehydrates an
// empty store on launch, so rebuilding costs only local-only fields.

@Suite
@MainActor
struct StoreRecoveryTests {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aHealthyStoreOpensAndIsNotQuarantined() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("LumiVault.store")

        let container = SwiftDataContainer.create(storeURL: storeURL)
        let context = container.mainContext
        context.insert(AlbumRecord(name: "Trip", year: "2026", month: "07", day: "28"))
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<AlbumRecord>()) == 1)
        // Nothing was moved aside — the ordinary path must not quarantine anything.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!siblings.contains { $0.hasPrefix("Unopenable-") })
    }

    @Test func anUnopenableStoreIsQuarantinedAndReplacedRatherThanCrashing() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("LumiVault.store")

        // A file that is not a SQLite database at all: the same class of outcome as
        // a half-migrated store — `addPersistentStore` throws — without needing to
        // stage a real interrupted migration.
        let garbage = Data("this is not a SQLite database".utf8)
        try garbage.write(to: storeURL)
        try Data("stale wal".utf8).write(to: URL(fileURLWithPath: storeURL.path + "-wal"))

        // The old behaviour here was `fatalError`, i.e. the app dies on launch.
        let container = SwiftDataContainer.create(storeURL: storeURL)

        // A working store, on the same path.
        let context = container.mainContext
        context.insert(AlbumRecord(name: "Rebuilt", year: "2026", month: "07", day: "28"))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<AlbumRecord>()) == 1)

        // The bad store was moved aside, not deleted — it may hold recoverable
        // local-only state, and destroying a user's database on a failed open is a
        // worse default than keeping a copy.
        let quarantine = try #require(SwiftDataContainer.quarantinedStoreURL)
        #expect(SwiftDataContainer.didRecoverFromUnopenableStore)
        #expect(FileManager.default.fileExists(atPath: quarantine.path))

        let moved = try FileManager.default.contentsOfDirectory(atPath: quarantine.path)
        #expect(moved.contains("LumiVault.store"))
        #expect(try Data(contentsOf: quarantine.appendingPathComponent("LumiVault.store")) == garbage,
                "the original bytes should be preserved verbatim for recovery")

        // The stale `-wal` must travel with it. Left behind, SQLite re-associates it
        // with the new store and reintroduces the state we just moved aside.
        //
        // Note the new store has a `-wal` of its own, so "no -wal exists" is the
        // wrong assertion — what matters is that the *stale bytes* are no longer
        // sitting next to the live store.
        #expect(moved.contains("LumiVault.store-wal"))
        #expect(try Data(contentsOf: quarantine.appendingPathComponent("LumiVault.store-wal"))
                == Data("stale wal".utf8))
        let liveWal = URL(fileURLWithPath: storeURL.path + "-wal")
        if FileManager.default.fileExists(atPath: liveWal.path) {
            #expect(try Data(contentsOf: liveWal) != Data("stale wal".utf8),
                    "the stale -wal is still beside the new store")
        }
    }

    @Test func anOpenFailureWithNoStoreOnDiskIsNotReportedAsRecovery() throws {
        // A container that will not open when there is no store file is failing for
        // some other reason — an invalid schema, an unwritable directory. Claiming
        // recovery there is a lie, and the old code proved it by leaving an empty
        // `Unopenable-<stamp>` directory behind on every launch attempt.
        //
        // Driven through `quarantineStore` rather than `create`, because the only
        // way to make `ModelContainer` fail with no store present is to break the
        // schema, which is not something a test can do to the app's real models.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("LumiVault.store")

        #expect(try SwiftDataContainer.quarantineStoreForTesting(at: storeURL) == nil)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!siblings.contains { $0.hasPrefix("Unopenable-") },
                "an empty quarantine directory was created for a store that does not exist")
    }

    @Test func twoQuarantinesInTheSameSecondDoNotCollide() throws {
        // The directory name used to be a second-resolution timestamp alone, so two
        // failures inside one second landed on the same path: `createDirectory`
        // succeeded on the existing directory and `moveItem` then threw on the
        // existing destination, silently leaving the second bad store in place.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<2 {
            let storeURL = dir.appendingPathComponent("LumiVault.store")
            try Data("garbage \(i)".utf8).write(to: storeURL)
            let quarantine = try #require(try SwiftDataContainer.quarantineStoreForTesting(at: storeURL))
            #expect(FileManager.default.fileExists(
                atPath: quarantine.appendingPathComponent("LumiVault.store").path
            ))
        }

        let quarantines = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("Unopenable-") }
        #expect(quarantines.count == 2, "the second quarantine overwrote the first")
    }

    @Test func recoveryLeavesTheCatalogUntouchedSinceThatIsTheRebuildSource() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("LumiVault.store")
        try Data("not a database".utf8).write(to: storeURL)

        // Recovery must not reach for the catalog itself — rehydration is
        // `SyncCoordinator`'s job on the next launch, and a container that deleted
        // or rewrote catalog.json would destroy the very thing it rebuilds from.
        let catalogURL = dir.appendingPathComponent("catalog.json")
        let catalog = Catalog(version: 1, lastUpdated: .now, years: [:])
        try catalog.save(to: catalogURL)
        let before = try Data(contentsOf: catalogURL)

        _ = SwiftDataContainer.create(storeURL: storeURL)

        #expect(try Data(contentsOf: catalogURL) == before)
    }
}
