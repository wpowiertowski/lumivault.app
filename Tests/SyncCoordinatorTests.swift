import Testing
import Foundation
import SwiftData
@testable import LumiVault

// MARK: - SyncCoordinator distribution
//
// PR #55 listed `pushAfterLocalChange` as untestable because `SyncCoordinator`
// had no init — every service was a hardcoded `let x = XService()` and the
// catalog path came straight from `Constants.Paths.resolvedCatalogURL`.
//
// The init added alongside these tests follows the pattern already used by
// `SettingsSyncService.init(syncURL:defaultsSuiteName:)` and `SyncService`'s
// test-only init. The catalog URL in particular is not an isolation nicety:
// `pushAfterLocalChange` *reads* and `restoreCatalog` *writes* that path, so
// without the seam these tests would rewrite the user's real
// ~/Pictures/LumiVault/catalog.json.

@Suite
@MainActor
struct SyncCoordinatorTests {

    @MainActor
    final class Fixture {
        let root: URL
        let catalogURL: URL
        let volumeURL: URL
        let defaults: UserDefaults
        let suiteName: String
        let catalogService = CatalogService()
        let backupService = CatalogBackupService()
        let container: ModelContainer

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("lumivault-synccoord-\(UUID().uuidString)", isDirectory: true)
            catalogURL = root.appendingPathComponent("catalog.json")
            volumeURL = root.appendingPathComponent("volume", isDirectory: true)
            try FileManager.default.createDirectory(at: volumeURL, withIntermediateDirectories: true)

            suiteName = "lumivault.synccoord.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName) ?? .standard

            container = try ModelContainer(
                for: ImageRecord.self, AlbumRecord.self, VolumeRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        func makeCoordinator() -> SyncCoordinator {
            let coordinator = SyncCoordinator(
                catalogService: catalogService,
                backupService: backupService,
                settingsSyncService: SettingsSyncService(
                    syncURL: root.appendingPathComponent("settings.json"),
                    defaultsSuiteName: suiteName
                ),
                catalogURL: catalogURL,
                defaults: defaults
            )
            coordinator.modelContainer = container
            return coordinator
        }

        /// Register a volume so `resolveVolumeSnapshots` has something to resolve.
        func registerVolume(id: String = "vol-1") throws {
            let record = VolumeRecord(
                volumeID: id, label: "TestVolume", mountPoint: volumeURL.path,
                bookmarkData: try BookmarkResolver.createBookmark(for: volumeURL)
            )
            container.mainContext.insert(record)
            try container.mainContext.save()
        }

        func seedCatalogOnDisk(album: String = "Trip") throws {
            let image = CatalogImage(
                filename: "one.heic", sha256: "aa11", sizeBytes: 10, par2Filename: ""
            )
            let catalog = Catalog(
                version: 1, lastUpdated: .now,
                years: ["2026": CatalogYear(months: ["07": CatalogMonth(
                    days: ["28": CatalogDay(albums: [album: CatalogAlbum(addedAt: .now, images: [image])])]
                )])]
            )
            try catalog.save(to: catalogURL)
        }
    }

    // MARK: - pushAfterLocalChange

    @Test func pushDistributesTheCatalogToEveryRegisteredVolume() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedCatalogOnDisk()
        try f.registerVolume()

        await f.makeCoordinator().pushAfterLocalChange()

        // The whole point of the push: every external volume gets a copy of
        // catalog.json, so any one of them can restore the archive on its own.
        let onVolume = f.volumeURL.appendingPathComponent("catalog.json")
        #expect(FileManager.default.fileExists(atPath: onVolume.path),
                "catalog was not distributed to the registered volume")

        let distributed = try Catalog.load(from: onVolume)
        #expect(distributed.years["2026"]?.months["07"]?.days["28"]?.albums["Trip"] != nil)
    }

    @Test func pushReloadsFromDiskByDefaultSoExternalMutationsAreNotLost() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.registerVolume()

        // The in-memory service starts empty; disk has an album written by some
        // other CatalogService instance (the deletion flows do exactly this).
        try f.seedCatalogOnDisk(album: "WrittenElsewhere")

        await f.makeCoordinator().pushAfterLocalChange(reloadFromDisk: true)

        let distributed = try Catalog.load(from: f.volumeURL.appendingPathComponent("catalog.json"))
        #expect(distributed.years["2026"]?.months["07"]?.days["28"]?.albums["WrittenElsewhere"] != nil,
                "reloadFromDisk did not pick up the on-disk catalog")
    }

    @Test func pushWithoutReloadDistributesTheInMemoryCatalogInstead() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.registerVolume()
        try f.seedCatalogOnDisk(album: "OnDiskOnly")

        // Callers that already mutated the catalog in memory pass false, so a
        // silently-failed save cannot resurrect deleted content from disk.
        await f.catalogService.addImage(
            CatalogImage(filename: "x.heic", sha256: "bb22", sizeBytes: 1, par2Filename: ""),
            toAlbum: "InMemoryOnly", year: "2026", month: "07", day: "28"
        )
        await f.makeCoordinator().pushAfterLocalChange(reloadFromDisk: false)

        let day = try Catalog.load(from: f.volumeURL.appendingPathComponent("catalog.json"))
            .years["2026"]?.months["07"]?.days["28"]
        #expect(day?.albums["InMemoryOnly"] != nil)
        #expect(day?.albums["OnDiskOnly"] == nil, "reloadFromDisk: false still read from disk")
    }

    @Test func pushSkipsICloudAndB2WhenBothAreDisabled() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedCatalogOnDisk()
        try f.registerVolume()

        // Neither flag set in this suite's defaults domain — the volume backup
        // must still happen, and the run must not hang or throw reaching for
        // credentials that do not exist.
        f.defaults.removeObject(forKey: "iCloudSyncEnabled")
        f.defaults.removeObject(forKey: "b2Enabled")

        await f.makeCoordinator().pushAfterLocalChange()

        #expect(FileManager.default.fileExists(
            atPath: f.volumeURL.appendingPathComponent("catalog.json").path))
    }

    @Test func pushSurvivesAVolumeThatCannotBeWritten() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedCatalogOnDisk()
        try f.registerVolume()

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: f.volumeURL.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: f.volumeURL.path)
        }

        // A read-only drive must not take the app down or abort the push; the
        // error is collected and reported, not thrown.
        await f.makeCoordinator().pushAfterLocalChange()

        // Assert the failure path was actually exercised rather than the write
        // quietly succeeding — otherwise this test passes for the wrong reason.
        #expect(!FileManager.default.fileExists(
            atPath: f.volumeURL.appendingPathComponent("catalog.json").path),
            "the volume was writable after all — this test no longer covers the failure path")

        // And the local catalog is untouched by the volume failure.
        #expect(FileManager.default.fileExists(atPath: f.catalogURL.path))
    }

    // MARK: - restoreCatalog

    @Test func restoreFromFileWritesTheCatalogLocallyAndLoadsIt() async throws {
        let f = try Fixture()
        defer { f.cleanup() }

        // A backup sitting somewhere else on disk.
        let backupURL = f.root.appendingPathComponent("backup.json")
        let image = CatalogImage(filename: "r.heic", sha256: "cc33", sizeBytes: 5, par2Filename: "")
        try Catalog(
            version: 1, lastUpdated: .now,
            years: ["2025": CatalogYear(months: ["01": CatalogMonth(
                days: ["02": CatalogDay(albums: ["Restored": CatalogAlbum(addedAt: .now, images: [image])])]
            )])]
        ).save(to: backupURL)

        let restored = try await f.makeCoordinator().restoreCatalog(from: .file(backupURL))

        #expect(restored.years["2025"]?.months["01"]?.days["02"]?.albums["Restored"] != nil)
        // It must also land at the coordinator's catalog path — a restore that
        // only returns a value leaves the app pointing at the old catalog.
        #expect(FileManager.default.fileExists(atPath: f.catalogURL.path))
        let onDisk = try Catalog.load(from: f.catalogURL)
        #expect(onDisk.years["2025"]?.months["01"]?.days["02"]?.albums["Restored"] != nil)
        // And the live service reflects it without a relaunch.
        let live = await f.catalogService.currentCatalog()
        #expect(live.years["2025"]?.months["01"]?.days["02"]?.albums["Restored"] != nil)
    }

    @Test func restoreFromAMissingFileThrowsInsteadOfClobberingTheLocalCatalog() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedCatalogOnDisk(album: "Existing")

        await #expect(throws: (any Error).self) {
            _ = try await f.makeCoordinator().restoreCatalog(
                from: .file(f.root.appendingPathComponent("does-not-exist.json"))
            )
        }

        // The pre-existing catalog must survive a failed restore.
        let onDisk = try Catalog.load(from: f.catalogURL)
        #expect(onDisk.years["2026"]?.months["07"]?.days["28"]?.albums["Existing"] != nil)
    }

    // MARK: - Catalog mutation helpers

    @Test func removingAnAlbumMutatesTheCatalogAndPersistsIt() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedCatalogOnDisk()

        let coordinator = f.makeCoordinator()
        try await f.catalogService.load(from: f.catalogURL)
        await coordinator.removeAlbumFromCatalog(name: "Trip", year: "2026", month: "07", day: "28")

        // Persisted, not just mutated in memory.
        let onDisk = try Catalog.load(from: f.catalogURL)
        #expect(onDisk.years["2026"]?.months["07"]?.days["28"]?.albums["Trip"] == nil)
    }

    @Test func updatingAB2FileIdPersistsToTheCatalogOnDisk() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedCatalogOnDisk()

        let coordinator = f.makeCoordinator()
        try await f.catalogService.load(from: f.catalogURL)
        await coordinator.updateImageB2FileId(sha256: "aa11", b2FileId: "4_zabc123")

        let image = try Catalog.load(from: f.catalogURL)
            .years["2026"]?.months["07"]?.days["28"]?.albums["Trip"]?.images.first
        #expect(image?.b2FileId == "4_zabc123")
    }

    // MARK: - Volume resolution

    @Test func volumeSnapshotsResolveOnlyBookmarksThatStillPointSomewhere() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedCatalogOnDisk()
        try f.registerVolume(id: "vol-good")

        // A second volume whose bookmark resolves to a directory that is gone —
        // the disconnected-drive case. It must be skipped, not crash the push.
        let ghostDir = f.root.appendingPathComponent("ghost", isDirectory: true)
        try FileManager.default.createDirectory(at: ghostDir, withIntermediateDirectories: true)
        let ghostBookmark = try BookmarkResolver.createBookmark(for: ghostDir)
        try FileManager.default.removeItem(at: ghostDir)
        f.container.mainContext.insert(VolumeRecord(
            volumeID: "vol-ghost", label: "Ghost", mountPoint: ghostDir.path,
            bookmarkData: ghostBookmark
        ))
        try f.container.mainContext.save()

        await f.makeCoordinator().pushAfterLocalChange()

        #expect(FileManager.default.fileExists(
            atPath: f.volumeURL.appendingPathComponent("catalog.json").path),
            "the healthy volume must still receive the catalog")
    }
}
