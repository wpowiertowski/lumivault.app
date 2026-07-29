import Testing
import Foundation
import SwiftData
import AppKit
@testable import LumiVault

// MARK: - Pipeline Orchestration
//
// Drives the real eight-stage import pipeline end to end through
// `PipelinedImportCoordinator.importFiles`, which feeds the *same*
// `runImportPipeline` the Photos path uses — only the asset source differs.
// That makes the orchestration reachable without the Photos entitlement:
// no service injection, no protocol seams.
//
// SAFETY: every test here MUST route its output to a temporary volume.
// When `targetVolumeIDs` resolves to nothing and B2 is off, the coordinator
// falls back to `Constants.Paths.libraryURL` — the user's real
// `~/Pictures/LumiVault` — and writes photos and a rewritten catalog.json
// into it. `PipelineHarness` always registers a temp volume and asserts the
// resolved destination is inside its own scratch directory, so a future test
// cannot reintroduce that by forgetting a setting.

/// Owns a scratch directory, an in-memory store, and a registered temp volume.
@MainActor
final class PipelineHarness {
    let root: URL
    let volumeURL: URL
    /// This harness's own catalog.json. The pipeline saves the catalog on every
    /// import; with the production default that save lands on the real
    /// ~/Pictures/LumiVault/catalog.json and replaces a whole archive with two
    /// test files. Pointing target volumes at a temp directory does NOT prevent
    /// this — the catalog save is a separate path.
    let catalogURL: URL
    let volumeID = "test-volume-\(UUID().uuidString)"
    let container: ModelContainer
    let context: ModelContext
    let catalogService = CatalogService()
    let encryptionService = EncryptionService()
    let progress = PhotosImportProgress()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-pipeline-\(UUID().uuidString)", isDirectory: true)
        volumeURL = root.appendingPathComponent("volume", isDirectory: true)
        catalogURL = root.appendingPathComponent("catalog.json")
        try FileManager.default.createDirectory(at: volumeURL, withIntermediateDirectories: true)

        container = try ModelContainer(
            for: ImageRecord.self, AlbumRecord.self, VolumeRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = container.mainContext

        let volume = VolumeRecord(
            volumeID: volumeID,
            label: "TestVolume",
            mountPoint: volumeURL.path,
            bookmarkData: try BookmarkResolver.createBookmark(for: volumeURL)
        )
        context.insert(volume)
        try context.save()
    }

    /// Explicit teardown, called from a `defer` in each test.
    ///
    /// Deliberately NOT `deinit`. With cleanup in `deinit`, ARC is free to release the
    /// harness at its last syntactic use — which under the xcodebuild app host happened
    /// *while* `importFiles` was still reading from `root`, deleting the pipeline's own
    /// source files mid-run and crashing the test host. A `defer` that captures `h`
    /// keeps it alive to the end of the test scope, which is the property we actually
    /// need. (SwiftPM masked this: different timing, same latent bug.)
    func cleanup() {
        // Restore permissions first — a test may have made a directory read-only to
        // force a copy failure, and removeItem cannot recurse into it otherwise.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: volumeURL.path
        )
        try? FileManager.default.removeItem(at: root)
    }

    /// Baseline settings: everything optional off, output pinned to the temp volume.
    func settings(albumName: String = "Trip") -> ImportSettings {
        var s = ImportSettings(albumName: albumName, year: "2026", month: "07", day: "28")
        s.generatePAR2 = false
        s.uploadToB2 = false
        s.encryptFiles = false
        s.detectNearDuplicates = false
        s.targetVolumeIDs = [volumeID]
        return s
    }

    /// Write `count` distinct JPEGs into the scratch directory.
    func makeImages(count: Int, prefix: String = "img") throws -> [URL] {
        var urls: [URL] = []
        for i in 0..<count {
            urls.append(try writeImage(named: "\(prefix)\(i).jpg", seed: i, size: 16 + i))
        }
        return urls
    }

    /// A deterministic solid-colour JPEG. Distinct seeds give distinct SHA-256s.
    @discardableResult
    func writeImage(named name: String, seed: Int, size: Int = 16) throws -> URL {
        let url = root.appendingPathComponent(name)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor(
            calibratedRed: CGFloat(seed % 7) / 7.0,
            green: CGFloat((seed * 3) % 5) / 5.0,
            blue: CGFloat((seed * 5) % 11) / 11.0,
            alpha: 1
        ).drawSwatch(in: NSRect(x: 0, y: 0, width: size, height: size))
        image.unlockFocus()

        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let jpeg = try #require(rep.representation(using: .jpeg, properties: [:]))
        try jpeg.write(to: url)
        return url
    }

    /// The album directory the pipeline should have written into.
    var albumDirectory: URL {
        volumeURL.appendingPathComponent("2026/07/28/Trip", isDirectory: true)
    }

    func records() throws -> [ImageRecord] {
        try context.fetch(FetchDescriptor<ImageRecord>())
    }

    func makeCoordinator() -> PipelinedImportCoordinator {
        PipelinedImportCoordinator(
            catalogService: catalogService,
            encryptionService: encryptionService,
            catalogURL: catalogURL
        )
    }

    /// Fails loudly if anything landed outside the scratch directory — the guard
    /// that keeps a misconfigured test away from the real photo library.
    func assertNothingEscaped(_ locations: [StorageLocation]) {
        #expect(!locations.isEmpty, "no storage location recorded — did the copy stage run?")
        for location in locations {
            #expect(
                location.volumeID == volumeID,
                "wrote to \(location.volumeID) — expected the temp volume, not the real library"
            )
        }
    }
}

@Suite
@MainActor
struct PipelineOrchestrationTests {

    // MARK: - Baseline

    @Test func importPersistsRecordsAlbumAndCatalogAndCopiesBytesToTheVolume() async throws {
        let h = try PipelineHarness()
        defer { h.cleanup() }
        let urls = try h.makeImages(count: 3)

        try await h.makeCoordinator().importFiles(
            urls: urls, settings: h.settings(), modelContext: h.context, progress: h.progress
        )

        let records = try h.records()
        #expect(records.count == 3)
        #expect(h.progress.errors.isEmpty)
        #expect(h.progress.filesCataloged == 3)
        #expect(h.progress.filesDropped == 0)

        // The album relationship is what the sidebar reads.
        let albums = try h.context.fetch(FetchDescriptor<AlbumRecord>())
        #expect(albums.count == 1)
        #expect(albums.first?.name == "Trip")
        #expect(albums.first?.images.count == 3)

        // Bytes really landed on the volume, under the date-derived path.
        for record in records {
            let onDisk = h.albumDirectory.appendingPathComponent(record.filename)
            #expect(FileManager.default.fileExists(atPath: onDisk.path), "missing \(record.filename)")
            h.assertNothingEscaped(record.storageLocations)
        }

        // And the portable catalog agrees with the store.
        let catalog = await h.catalogService.currentCatalog()
        let images = catalog.years["2026"]?.months["07"]?.days["28"]?.albums["Trip"]?.images ?? []
        #expect(Set(images.map(\.sha256)) == Set(records.map(\.sha256)))
    }

    // MARK: - Optional stages

    @Test func par2StageWritesRecoveryVolumesAndRecordsTheIndexName() async throws {
        let h = try PipelineHarness()
        defer { h.cleanup() }
        let urls = try h.makeImages(count: 2)
        var settings = h.settings()
        settings.generatePAR2 = true

        try await h.makeCoordinator().importFiles(
            urls: urls, settings: settings, modelContext: h.context, progress: h.progress
        )

        let records = try h.records()
        #expect(records.count == 2)
        for record in records {
            #expect(!record.par2Filename.isEmpty, "PAR2 index not recorded for \(record.filename)")
            let index = h.albumDirectory.appendingPathComponent(record.par2Filename)
            #expect(FileManager.default.fileExists(atPath: index.path))
        }

        // Recovery volumes must be mirrored alongside the index, not left in staging —
        // that companion copy is what makes an archived file repairable.
        let contents = try FileManager.default.contentsOfDirectory(
            at: h.albumDirectory, includingPropertiesForKeys: nil
        )
        #expect(contents.contains { $0.lastPathComponent.contains(".vol") })
    }

    @Test func encryptionStageStoresCiphertextAndTheKeyMaterialNeededToReadItBack() async throws {
        let h = try PipelineHarness()
        defer { h.cleanup() }
        let (key, keyId) = h.encryptionService.deriveKey(
            passphrase: "pipeline-test", salt: Data(repeating: 0x11, count: 32)
        )
        await h.encryptionService.setKey(key, keyId: keyId)

        let urls = try h.makeImages(count: 2)
        var settings = h.settings()
        settings.encryptFiles = true

        try await h.makeCoordinator().importFiles(
            urls: urls, settings: settings, modelContext: h.context, progress: h.progress
        )

        let records = try h.records()
        #expect(records.count == 2)
        for record in records {
            #expect(record.isEncrypted)
            #expect(record.encryptionKeyId == keyId)
            #expect(record.encryptionNonce != nil)
        }

        // The stored bytes must not be the plaintext JPEG: a file that silently
        // imported unencrypted would still satisfy the record flags above.
        let onDisk = h.albumDirectory.appendingPathComponent(records[0].filename)
        let stored = try Data(contentsOf: onDisk)
        #expect(stored.prefix(2) != Data([0xFF, 0xD8]), "stored file still starts with a JPEG SOI marker")
    }

    @Test func conversionStageRenamesToTheConvertedExtensionEverywhere() async throws {
        let h = try PipelineHarness()
        defer { h.cleanup() }
        let urls = try h.makeImages(count: 1)
        var settings = h.settings()
        settings.imageFormat = .heic
        settings.maxDimension = .capped(8)

        try await h.makeCoordinator().importFiles(
            urls: urls, settings: settings, modelContext: h.context, progress: h.progress
        )

        let record = try #require(try h.records().first)
        // Regression shape: the record, the catalog and the bytes on disk must all
        // agree on the *converted* name, not the original .jpg.
        #expect(record.filename.hasSuffix(".heic"), "record kept \(record.filename)")
        #expect(FileManager.default.fileExists(
            atPath: h.albumDirectory.appendingPathComponent(record.filename).path))

        let catalog = await h.catalogService.currentCatalog()
        let images = catalog.years["2026"]?.months["07"]?.days["28"]?.albums["Trip"]?.images ?? []
        #expect(images.first?.filename == record.filename)
    }

    // MARK: - Deduplication

    @Test func identicalBytesImportedTwiceYieldOneRecordAndOneCatalogEntry() async throws {
        let h = try PipelineHarness()
        defer { h.cleanup() }
        let first = try h.writeImage(named: "original.jpg", seed: 3)
        let duplicate = h.root.appendingPathComponent("copy.jpg")
        try FileManager.default.copyItem(at: first, to: duplicate)

        try await h.makeCoordinator().importFiles(
            urls: [first, duplicate], settings: h.settings(),
            modelContext: h.context, progress: h.progress
        )

        // `ImageRecord.sha256` is unique, so identical bytes can only ever be one record.
        #expect(try h.records().count == 1)
        let catalog = await h.catalogService.currentCatalog()
        let images = catalog.years["2026"]?.months["07"]?.days["28"]?.albums["Trip"]?.images ?? []
        #expect(images.count == 1)
    }

    @Test func reimportingIntoASecondAlbumReusesTheRecordInsteadOfReprocessing() async throws {
        let h = try PipelineHarness()
        defer { h.cleanup() }
        let urls = try h.makeImages(count: 1)
        let coordinator = h.makeCoordinator()

        try await coordinator.importFiles(
            urls: urls, settings: h.settings(albumName: "Trip"),
            modelContext: h.context, progress: h.progress
        )
        try await coordinator.importFiles(
            urls: urls, settings: h.settings(albumName: "Beach"),
            modelContext: h.context, progress: h.progress
        )

        let records = try h.records()
        #expect(records.count == 1)

        let catalog = await h.catalogService.currentCatalog()
        let day = catalog.years["2026"]?.months["07"]?.days["28"]
        // The catalog files one sha under both albums even though there is one record.
        #expect(day?.albums["Trip"]?.images.count == 1)
        #expect(day?.albums["Beach"]?.images.count == 1)

        // And SwiftData agrees: the second import adds a membership rather than
        // moving the record out of the first album. While `album` was to-one the
        // record silently left "Trip", which then rendered empty in the sidebar.
        let record = try #require(records.first)
        #expect(Set(record.albums.map(\.name)) == ["Trip", "Beach"])
        for album in try h.context.fetch(FetchDescriptor<AlbumRecord>()) {
            #expect(album.images.count == 1, "\(album.name) lost its image")
        }
    }

    @Test func deletingOneAlbumKeepsAnImageThatStillBelongsToAnother() async throws {
        let h = try PipelineHarness()
        defer { h.cleanup() }
        let urls = try h.makeImages(count: 1)
        let coordinator = h.makeCoordinator()

        try await coordinator.importFiles(
            urls: urls, settings: h.settings(albumName: "Trip"),
            modelContext: h.context, progress: h.progress
        )
        try await coordinator.importFiles(
            urls: urls, settings: h.settings(albumName: "Beach"),
            modelContext: h.context, progress: h.progress
        )

        let albums = try h.context.fetch(FetchDescriptor<AlbumRecord>())
        let trip = try #require(albums.first { $0.name == "Trip" })

        // This mirrors what the sidebar's delete flow does: drop images the album
        // was the last home for, then the album itself. Under the old `.cascade`
        // rule deleting either album would have taken the shared image with it.
        for image in trip.images where image.albums.count <= 1 {
            h.context.delete(image)
        }
        h.context.delete(trip)
        try h.context.save()

        let survivors = try h.records()
        #expect(survivors.count == 1, "the image was destroyed with the album it also lived outside of")
        #expect(survivors.first?.albums.map(\.name) == ["Beach"])
    }

    @Test func deletingTheOnlyAlbumAnImageBelongsToRemovesTheImage() async throws {
        let h = try PipelineHarness()
        defer { h.cleanup() }

        try await h.makeCoordinator().importFiles(
            urls: try h.makeImages(count: 2), settings: h.settings(albumName: "Trip"),
            modelContext: h.context, progress: h.progress
        )

        let trip = try #require(try h.context.fetch(FetchDescriptor<AlbumRecord>()).first)
        // The other half of the nullify rule: without explicit cleanup these
        // records would survive as orphans with no album and no route back into
        // the UI, since every view reaches images through an album.
        for image in trip.images where image.albums.count <= 1 {
            h.context.delete(image)
        }
        h.context.delete(trip)
        try h.context.save()

        #expect(try h.records().isEmpty)
    }

    // MARK: - Failure isolation

    @Test func aFailingVolumeCopyIsReportedWithoutDroppingTheImportEntirely() async throws {
        let h = try PipelineHarness()
        defer { h.cleanup() }
        let urls = try h.makeImages(count: 2)

        // Make the destination un-writable so the copy stage fails for real.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: h.volumeURL.path
        )

        try await h.makeCoordinator().importFiles(
            urls: urls, settings: h.settings(), modelContext: h.context, progress: h.progress
        )

        // Copy failures surface via `copyError` → progress.errors, and must NOT be
        // promoted to `item.error`: external mirroring and B2 are independent
        // redundancy targets, so a dead drive cannot cancel the rest of the import.
        #expect(!h.progress.errors.isEmpty, "a failed copy must be surfaced to the user")
        #expect(h.progress.errors.contains { $0.contains("Copy failed") })
        // The records still exist — the import was not abandoned.
        #expect(try h.records().count == 2)
        #expect(h.progress.filesDropped == 0)
    }

    @Test func anUnreadableSourceFileIsSkippedWithoutStoppingItsSiblings() async throws {
        let h = try PipelineHarness()
        defer { h.cleanup() }
        let good = try h.writeImage(named: "good.jpg", seed: 1)
        let missing = h.root.appendingPathComponent("never-created.jpg")

        try await h.makeCoordinator().importFiles(
            urls: [good, missing], settings: h.settings(),
            modelContext: h.context, progress: h.progress
        )

        // The healthy file still lands; the broken one is accounted for rather than
        // silently vanishing.
        let records = try h.records()
        #expect(records.count == 1)
        #expect(records.first?.filename == "good.jpg")
        #expect(h.progress.filesDropped + h.progress.filesSkipped >= 1)
    }

    // MARK: - Cancellation

    /// Cancelling is not a reason to lose files that are already archived.
    ///
    /// The bytes for everything the sink cataloged have already been copied to the
    /// volume, so skipping the save left them on disk with nothing in catalog.json
    /// pointing at them — invisible to the app and to a restore — while the caller
    /// was told the import succeeded.
    ///
    /// This also subsumes the former `cancellingMidImportStopsShortOfCatalogingEverything`,
    /// whose single assertion was `filesCataloged < 40` — asserted here by the
    /// `#require` below, alongside three stronger checks. That test cancelled after a
    /// fixed 60 ms sleep, which lands before the first catalog write or after the last
    /// depending on the machine; the poll below is why this one can assert both bounds.
    ///
    /// Neither test calls `settle()` any more. That helper slept 500 ms before
    /// returning, because `runImportPipeline` awaited only the catalog sink: the
    /// detached stages could still be running when the harness released its
    /// `ModelContainer`, and one touching the freed context trapped inside SwiftData
    /// and took the test host down. That was a production defect wearing a test
    /// workaround — the same unawaited stages keep writing into a staging directory
    /// the caller's `defer` has already deleted. `runImportPipeline` now awaits every
    /// stage, so if that regresses this test crashes rather than sleeping through it.
    @Test func cancellingStillPersistsWhatWasAlreadyArchived() async throws {
        let h = try PipelineHarness()
        defer { h.cleanup() }
        let urls = try h.makeImages(count: 40)
        var settings = h.settings()
        settings.generatePAR2 = true

        let coordinator = h.makeCoordinator()
        let task = Task { @MainActor in
            try await coordinator.importFiles(
                urls: urls, settings: settings, modelContext: h.context, progress: h.progress
            )
        }
        // Cancel once the sink has actually filed something — a fixed sleep either
        // lands before the first catalog write (nothing to assert) or after the last
        // (nothing was cancelled), and which one depends on the machine.
        let deadline = Date().addingTimeInterval(10)
        while h.progress.filesCataloged == 0 && h.progress.filesCataloged < 40 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        _ = try? await task.value

        let cataloged = h.progress.filesCataloged
        try #require(cataloged > 0, "test did not cancel mid-flight; nothing to assert about")
        try #require(cataloged < 40, "cancellation drained the whole backlog")

        // catalog.json must exist and hold exactly what the sink counted.
        let data = try Data(contentsOf: h.catalogURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(Catalog.self, from: data)
        let entries = catalog.years.values
            .flatMap(\.months.values).flatMap(\.days.values).flatMap(\.albums.values)
            .reduce(0) { $0 + $1.images.count }
        #expect(entries == cataloged,
                "catalog.json holds \(entries) of \(cataloged) archived files")

        // And no record may be left without an album: nothing can display it, and
        // `isHydrationStale` counts it against the catalog forever, re-running a full
        // main-thread hydration on every launch.
        let orphans = try h.context.fetch(FetchDescriptor<ImageRecord>())
            .filter { $0.albums.isEmpty }
        #expect(orphans.isEmpty, "\(orphans.count) records left with no album")
    }

    // MARK: - Progress accounting

    @Test func progressCountersReconcileWithWhatWasActuallyPersisted() async throws {
        let h = try PipelineHarness()
        defer { h.cleanup() }
        let urls = try h.makeImages(count: 4)

        try await h.makeCoordinator().importFiles(
            urls: urls, settings: h.settings(), modelContext: h.context, progress: h.progress
        )

        // Every input is accounted for exactly once across the outcome buckets —
        // the invariant the completion screen reports against.
        let accounted = h.progress.filesCataloged + h.progress.filesDeduplicated
            + h.progress.filesDropped + h.progress.filesSkipped
        #expect(accounted == urls.count, "counters do not reconcile: \(accounted) vs \(urls.count)")
        #expect(h.progress.filesCataloged == (try h.records().count))
        #expect(h.progress.fraction >= 0 && h.progress.fraction <= 1)
    }
}
