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

    // MARK: - Sync (push+pull)

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
}
