import Testing
import Foundation
@testable import LumiVault

// MARK: - SyncService Tests
//
// Exercises pushToICloud / pullFromICloud against a temp directory instead of
// the iCloud ubiquity container, using the test-only initializer that bypasses
// NSFileCoordinator.

@Suite
@MainActor
struct SyncServiceTests {

    // MARK: - Helpers

    func makeTempSyncURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-sync-\(UUID().uuidString)")
            .appendingPathComponent("catalog.json")
    }

    /// Convenience: build a Catalog containing a single album/image at a fixed timestamp.
    func makeCatalog(
        albumName: String,
        imageName: String,
        sha256: String,
        lastUpdated: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Catalog {
        let image = CatalogImage(
            filename: imageName,
            sha256: sha256,
            sizeBytes: 1024,
            par2Filename: "\(imageName).par2"
        )
        let album = CatalogAlbum(addedAt: lastUpdated, images: [image])
        return Catalog(
            version: 1,
            lastUpdated: lastUpdated,
            years: ["2025": CatalogYear(months: ["07": CatalogMonth(days: ["15": CatalogDay(albums: [albumName: album])])])]
        )
    }

    // MARK: - Push

    @Test func pushWritesEncodedCatalogToDisk() async throws {
        let syncURL = makeTempSyncURL()
        defer { try? FileManager.default.removeItem(at: syncURL.deletingLastPathComponent()) }

        let catalogService = CatalogService()
        let spec = TestFixtures.files[0]
        await catalogService.addImage(
            CatalogImage(
                filename: spec.name,
                sha256: spec.sha256,
                sizeBytes: Int64(spec.size),
                par2Filename: spec.par2Name
            ),
            toAlbum: spec.album,
            year: spec.year,
            month: spec.month,
            day: spec.day
        )

        let sync = SyncService(catalogService: catalogService, syncURL: syncURL)
        #expect(await sync.isICloudAvailable == true)

        try await sync.pushToICloud()

        // File must exist and decode back to a Catalog with the same image.
        #expect(FileManager.default.fileExists(atPath: syncURL.path))
        let decoded = try Catalog.load(from: syncURL)
        let images = decoded.years[spec.year]?.months[spec.month]?.days[spec.day]?
            .albums[spec.album]?.images ?? []
        #expect(images.first?.sha256 == spec.sha256)
    }

    @Test func pushCreatesParentDirectoryWhenMissing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-sync-\(UUID().uuidString)")
            .appendingPathComponent("nested")
            .appendingPathComponent("deeper")
        let syncURL = dir.appendingPathComponent("catalog.json")
        defer {
            try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent())
        }

        #expect(FileManager.default.fileExists(atPath: dir.path) == false)

        let sync = SyncService(catalogService: CatalogService(), syncURL: syncURL)
        try await sync.pushToICloud()

        #expect(FileManager.default.fileExists(atPath: syncURL.path))
    }

    // MARK: - Pull

    @Test func pullReturnsNilWhenFileMissing() async throws {
        let syncURL = makeTempSyncURL()
        // Do not create the file — pull should report nil rather than throwing.

        let sync = SyncService(catalogService: CatalogService(), syncURL: syncURL)
        let result = try await sync.pullFromICloud()
        #expect(result == nil)
    }

    @Test func pullDecodesRemoteAndMergesIntoCatalog() async throws {
        let syncURL = makeTempSyncURL()
        let dir = syncURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a "remote" catalog to disk that has an album the local service doesn't.
        let remote = makeCatalog(
            albumName: "RemoteTrip",
            imageName: "remote.heic",
            sha256: "1111111111111111111111111111111111111111111111111111111111111111"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(remote).write(to: syncURL, options: .atomic)

        let catalogService = CatalogService()
        let sync = SyncService(catalogService: catalogService, syncURL: syncURL)

        let merged = try await sync.pullFromICloud()
        #expect(merged != nil)

        let images = merged?.years["2025"]?.months["07"]?.days["15"]?
            .albums["RemoteTrip"]?.images ?? []
        #expect(images.first?.sha256 == "1111111111111111111111111111111111111111111111111111111111111111")
    }

    @Test func pullUnionsRemoteImagesWithLocalAlbum() async throws {
        let syncURL = makeTempSyncURL()
        let dir = syncURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Local: one image in "Shared" album.
        let catalogService = CatalogService()
        let localSha = "aaaa000000000000000000000000000000000000000000000000000000000000"
        await catalogService.addImage(
            CatalogImage(filename: "local.heic", sha256: localSha, sizeBytes: 100, par2Filename: "local.heic.par2"),
            toAlbum: "Shared", year: "2025", month: "07", day: "15"
        )

        // Remote: a different image in the same "Shared" album.
        let remoteSha = "bbbb000000000000000000000000000000000000000000000000000000000000"
        let remote = makeCatalog(albumName: "Shared", imageName: "remote.heic", sha256: remoteSha)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(remote).write(to: syncURL, options: .atomic)

        let sync = SyncService(catalogService: catalogService, syncURL: syncURL)
        let merged = try await sync.pullFromICloud()

        let hashes = Set((merged?.years["2025"]?.months["07"]?.days["15"]?
            .albums["Shared"]?.images ?? []).map(\.sha256))
        #expect(hashes == [localSha, remoteSha])
    }

    // MARK: - Round-trip

    @Test func pushThenPullRoundTrip() async throws {
        let syncURL = makeTempSyncURL()
        let dir = syncURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Producer catalog with an album.
        let producerCatalog = CatalogService()
        let spec = TestFixtures.files[2]   // mountain.heic
        await producerCatalog.addImage(
            CatalogImage(filename: spec.name, sha256: spec.sha256,
                         sizeBytes: Int64(spec.size), par2Filename: spec.par2Name),
            toAlbum: spec.album, year: spec.year, month: spec.month, day: spec.day
        )
        let producer = SyncService(catalogService: producerCatalog, syncURL: syncURL)
        try await producer.pushToICloud()

        // Fresh consumer reads what the producer wrote.
        let consumerCatalog = CatalogService()
        let consumer = SyncService(catalogService: consumerCatalog, syncURL: syncURL)
        let merged = try await consumer.pullFromICloud()

        let images = merged?.years[spec.year]?.months[spec.month]?.days[spec.day]?
            .albums[spec.album]?.images ?? []
        #expect(images.contains { $0.sha256 == spec.sha256 })
    }

    // MARK: - Sync (echo suppression / push-if-changed)

    private func modificationDate(of url: URL) throws -> Date {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date ?? .distantPast
    }

    @Test func syncSeedsMissingTargetAndReportsNoRemoteChanges() async throws {
        let syncURL = makeTempSyncURL()
        defer { try? FileManager.default.removeItem(at: syncURL.deletingLastPathComponent()) }

        let catalogService = CatalogService()
        let spec = TestFixtures.files[0]
        await catalogService.addImage(
            CatalogImage(filename: spec.name, sha256: spec.sha256,
                         sizeBytes: Int64(spec.size), par2Filename: spec.par2Name),
            toAlbum: spec.album, year: spec.year, month: spec.month, day: spec.day
        )
        let sync = SyncService(catalogService: catalogService, syncURL: syncURL)

        let hasRemoteChanges = try await sync.sync()

        #expect(hasRemoteChanges == false)
        #expect(FileManager.default.fileExists(atPath: syncURL.path))
    }

    @Test func syncIgnoresEchoOfOwnPush() async throws {
        // A metadata-query event for our own write must not trigger another
        // pull-merge-push cycle — that feedback loop re-synced the catalog
        // every ~2s and hung the main thread.
        let syncURL = makeTempSyncURL()
        defer { try? FileManager.default.removeItem(at: syncURL.deletingLastPathComponent()) }

        let catalogService = CatalogService()
        let spec = TestFixtures.files[0]
        await catalogService.addImage(
            CatalogImage(filename: spec.name, sha256: spec.sha256,
                         sizeBytes: Int64(spec.size), par2Filename: spec.par2Name),
            toAlbum: spec.album, year: spec.year, month: spec.month, day: spec.day
        )
        let sync = SyncService(catalogService: catalogService, syncURL: syncURL)

        _ = try await sync.sync()
        let dateAfterSeed = try modificationDate(of: syncURL)

        let secondPass = try await sync.sync()

        #expect(secondPass == false)
        #expect(try modificationDate(of: syncURL) == dateAfterSeed)
    }

    @Test func syncAbsorbsRemoteChangesAndPushesUnion() async throws {
        let syncURL = makeTempSyncURL()
        let dir = syncURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Local: image A. Remote (written externally, as if by another Mac): image B.
        let catalogService = CatalogService()
        let localSha = "aaaa000000000000000000000000000000000000000000000000000000000000"
        await catalogService.addImage(
            CatalogImage(filename: "local.heic", sha256: localSha, sizeBytes: 100, par2Filename: "local.heic.par2"),
            toAlbum: "Shared", year: "2025", month: "07", day: "15"
        )
        let remoteSha = "bbbb000000000000000000000000000000000000000000000000000000000000"
        let remote = makeCatalog(albumName: "Shared", imageName: "remote.heic", sha256: remoteSha)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(remote).write(to: syncURL, options: .atomic)

        let sync = SyncService(catalogService: catalogService, syncURL: syncURL)
        let hasRemoteChanges = try await sync.sync()

        #expect(hasRemoteChanges == true)
        // The target must now hold the union (merged result was pushed back).
        let decoded = try Catalog.load(from: syncURL)
        let hashes = Set((decoded.years["2025"]?.months["07"]?.days["15"]?
            .albums["Shared"]?.images ?? []).map(\.sha256))
        #expect(hashes == [localSha, remoteSha])
    }

    @Test func syncDoesNotRewriteTargetWhenMergeMatchesRemote() async throws {
        // Local is empty and remote is encoded exactly the way the service
        // encodes — the merge result byte-equals the target, so no write may
        // happen (a write would re-trigger the metadata query), but the caller
        // is still told to hydrate. A follow-up sync must read as settled.
        let syncURL = makeTempSyncURL()
        let dir = syncURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Future lastUpdated so merge's max() keeps the remote timestamp.
        let remote = makeCatalog(
            albumName: "RemoteOnly",
            imageName: "remote.heic",
            sha256: "cccc000000000000000000000000000000000000000000000000000000000000",
            lastUpdated: Date(timeIntervalSince1970: 4_102_444_800)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(remote).write(to: syncURL, options: .atomic)
        let dateAfterRemoteWrite = try modificationDate(of: syncURL)

        let sync = SyncService(catalogService: CatalogService(), syncURL: syncURL)

        let firstPass = try await sync.sync()
        #expect(firstPass == true)
        #expect(try modificationDate(of: syncURL) == dateAfterRemoteWrite)

        let secondPass = try await sync.sync()
        #expect(secondPass == false)
    }

    @Test func syncErrorPropagatesWhenRemoteIsCorruptJSON() async throws {
        let syncURL = makeTempSyncURL()
        let dir = syncURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a non-JSON file to syncURL so decode fails.
        try Data("not json".utf8).write(to: syncURL)

        let sync = SyncService(catalogService: CatalogService(), syncURL: syncURL)
        await #expect(throws: Error.self) {
            _ = try await sync.pullFromICloud()
        }
    }

    // MARK: - Sync (stranded local changes / target reseed)

    /// A local mutation that was never separately pushed (e.g. an integrity
    /// heal updates the catalog but doesn't call the push path) must still reach
    /// the sync target on the next sync. The old echo short-circuit returned
    /// early whenever the target matched the last push and left the change
    /// stranded for the rest of the session.
    @Test func syncPushesLocalChangeThatWasNeverPushed() async throws {
        let syncURL = makeTempSyncURL()
        defer { try? FileManager.default.removeItem(at: syncURL.deletingLastPathComponent()) }

        let catalogService = CatalogService()
        let shaA = "aaaa000000000000000000000000000000000000000000000000000000000000"
        await catalogService.addImage(
            CatalogImage(filename: "a.heic", sha256: shaA, sizeBytes: 100, par2Filename: "a.heic.par2"),
            toAlbum: "Shared", year: "2025", month: "07", day: "15"
        )
        let sync = SyncService(catalogService: catalogService, syncURL: syncURL)

        // Seed the target with just image A.
        _ = try await sync.sync()

        // A local-only change lands (not routed through pushToICloud).
        let shaB = "bbbb000000000000000000000000000000000000000000000000000000000000"
        await catalogService.addImage(
            CatalogImage(filename: "b.heic", sha256: shaB, sizeBytes: 100, par2Filename: "b.heic.par2"),
            toAlbum: "Shared", year: "2025", month: "07", day: "15"
        )

        _ = try await sync.sync()

        // The target must now carry the local addition.
        let decoded = try Catalog.load(from: syncURL)
        let hashes = Set((decoded.years["2025"]?.months["07"]?.days["15"]?
            .albums["Shared"]?.images ?? []).map(\.sha256))
        #expect(hashes == [shaA, shaB])
    }

    /// If the sync target is deleted or evicted after our last push, the next
    /// sync must re-seed it — the old `data == lastPushedData` skip in the push
    /// path left a deleted target missing forever.
    @Test func syncReseedsTargetAfterItIsDeleted() async throws {
        let syncURL = makeTempSyncURL()
        defer { try? FileManager.default.removeItem(at: syncURL.deletingLastPathComponent()) }

        let catalogService = CatalogService()
        let spec = TestFixtures.files[0]
        await catalogService.addImage(
            CatalogImage(filename: spec.name, sha256: spec.sha256,
                         sizeBytes: Int64(spec.size), par2Filename: spec.par2Name),
            toAlbum: spec.album, year: spec.year, month: spec.month, day: spec.day
        )
        let sync = SyncService(catalogService: catalogService, syncURL: syncURL)

        _ = try await sync.sync()
        #expect(FileManager.default.fileExists(atPath: syncURL.path))

        // Simulate the container being cleared / the file evicted.
        try FileManager.default.removeItem(at: syncURL)
        #expect(FileManager.default.fileExists(atPath: syncURL.path) == false)

        _ = try await sync.sync()
        #expect(FileManager.default.fileExists(atPath: syncURL.path))
    }

    // MARK: - Merge convergence

    /// Two Macs that each contribute a different image to the same album must
    /// converge on identical content after exchanging catalogs — otherwise each
    /// keeps pushing its own ordering and they ping-pong catalog.json forever.
    @Test func mergeConvergesRegardlessOfContributionOrder() async throws {
        let shaX = "1111000000000000000000000000000000000000000000000000000000000000"
        let shaY = "2222000000000000000000000000000000000000000000000000000000000000"

        let macA = CatalogService()
        await macA.addImage(
            CatalogImage(filename: "x.heic", sha256: shaX, sizeBytes: 1, par2Filename: "x.par2"),
            toAlbum: "Trip", year: "2025", month: "07", day: "15"
        )
        let macB = CatalogService()
        await macB.addImage(
            CatalogImage(filename: "y.heic", sha256: shaY, sizeBytes: 1, par2Filename: "y.par2"),
            toAlbum: "Trip", year: "2025", month: "07", day: "15"
        )

        let mergedA = await macA.merge(remote: await macB.currentCatalog())
        let mergedB = await macB.merge(remote: await macA.currentCatalog())

        #expect(mergedA.contentEquals(mergedB))
        // Deterministic (sorted) image order on both sides.
        let orderA = (mergedA.years["2025"]?.months["07"]?.days["15"]?.albums["Trip"]?.images ?? []).map(\.sha256)
        let orderB = (mergedB.years["2025"]?.months["07"]?.days["15"]?.albums["Trip"]?.images ?? []).map(\.sha256)
        #expect(orderA == [shaX, shaY])
        #expect(orderB == [shaX, shaY])
    }

    /// A field that differs for the same image (a b2FileId reassigned by a heal
    /// on one Mac) must reconcile the same way on both Macs so they converge.
    @Test func mergeReconcilesDivergentB2FileIdCommutatively() async throws {
        let sha = "3333000000000000000000000000000000000000000000000000000000000000"

        func service(b2FileId: String?) async -> CatalogService {
            let s = CatalogService()
            await s.addImage(
                CatalogImage(filename: "p.heic", sha256: sha, sizeBytes: 1,
                             par2Filename: "p.par2", b2FileId: b2FileId),
                toAlbum: "Trip", year: "2025", month: "07", day: "15"
            )
            return s
        }

        let macA = await service(b2FileId: "F1")
        let macB = await service(b2FileId: nil)

        let mergedA = await macA.merge(remote: await macB.currentCatalog())
        let mergedB = await macB.merge(remote: await macA.currentCatalog())

        #expect(mergedA.contentEquals(mergedB))
        // Non-nil healed id wins on both sides.
        let idA = mergedA.years["2025"]?.months["07"]?.days["15"]?.albums["Trip"]?.images.first?.b2FileId
        #expect(idA == "F1")
    }
}
