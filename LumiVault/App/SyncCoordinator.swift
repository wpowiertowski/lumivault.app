import Foundation
import SwiftUI
import SwiftData
import os

/// App-level coordinator that owns the shared CatalogService and SyncService,
/// wires iCloud monitoring, and exposes sync state to SwiftUI views.
@Observable
final class SyncCoordinator: @unchecked Sendable {
    private(set) var syncStatus: SyncStatus = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?
    private(set) var isICloudAvailable: Bool = false
    private(set) var catalogIntegrity: Catalog.IntegrityStatus?

    private let catalogService = CatalogService()
    private let backupService = CatalogBackupService()
    private var syncService: SyncService?
    private let settingsSyncService = SettingsSyncService()
    private var isSyncing = false
    private var settingsPushDebounce: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    var modelContainer: ModelContainer?

    enum SyncStatus: Sendable {
        case idle, syncing, synced, error, disabled
    }

    // MARK: - Setup

    func setup() async {
        // Move a pre-existing catalog out of the sandbox container into the user-accessible
        // library, one time, before anything reads it.
        migrateLegacyCatalogIfNeeded()

        // Load local catalog
        let catalogURL = Constants.Paths.resolvedCatalogURL

        // Verify catalog integrity before loading
        if FileManager.default.fileExists(atPath: catalogURL.path) {
            let status = await MainActor.run { Catalog.verifyIntegrity(at: catalogURL) }
            await MainActor.run { catalogIntegrity = status }
        }

        try? await catalogService.load(from: catalogURL)

        // Initialize sync service
        let service = SyncService(catalogService: catalogService)
        self.syncService = service

        let available = await service.isICloudAvailable
        await MainActor.run { self.isICloudAvailable = available }

        // If iCloud sync is enabled, pull on launch and start monitoring
        let enabled = await MainActor.run {
            UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")
        }

        if enabled && available {
            await performSync()
            await startMonitoring()
        }

        // Push local preference changes (import defaults, B2, encryption, …) to the
        // synced settings document. Debounced; syncSettings() is a no-op when nothing
        // in the document actually changed, so unrelated defaults writes are cheap.
        await MainActor.run {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: UserDefaults.standard,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.settingsPushDebounce?.cancel()
                    self.settingsPushDebounce = Task {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        await self.syncSettings()
                    }
                }
            }
        }
    }

    // MARK: - Public API

    func performSync() async {
        guard let service = syncService else { return }
        // Claim the sync slot atomically: read-and-set in a single MainActor hop so two
        // concurrent callers (launch sync, manual trigger, iCloud metadata callback) can't
        // both pass the guard and run overlapping pull-merge-push cycles on catalog.json.
        let claimed = await MainActor.run { () -> Bool in
            guard !isSyncing else { return false }
            isSyncing = true
            return true
        }
        guard claimed else { return }

        await MainActor.run {
            syncStatus = .syncing
            lastError = nil
        }

        do {
            let hasRemoteChanges = try await service.sync()
            if hasRemoteChanges {
                // Rebuild SwiftData from the merged catalog so @Query-backed views reflect
                // albums/images that arrived from other Macs. Without this, a second Mac
                // pulls catalog.json but the sidebar and grid stay empty. Skipped when the
                // sync was an echo of our own push — hydration is expensive main-actor work.
                let merged = await catalogService.currentCatalog()
                await MainActor.run { hydrateSwiftData(from: merged) }
            }
            await syncSettings()
            await MainActor.run {
                syncStatus = .synced
                lastSyncedAt = .now
            }
        } catch {
            await MainActor.run {
                syncStatus = .error
                lastError = error.localizedDescription
            }
        }

        await MainActor.run { isSyncing = false }
    }

    /// Push local catalog to iCloud after a local mutation (export, delete, etc.),
    /// and distribute catalog.json to all external volumes and B2.
    ///
    /// - Parameter reloadFromDisk: When `true` (default), reloads the catalog from disk before
    ///   distributing. Set to `false` when the in-memory catalog was already updated directly
    ///   (e.g. after deletion via `removeAlbumFromCatalog`), so the reload does not risk
    ///   restoring stale data if the prior save failed silently.
    func pushAfterLocalChange(reloadFromDisk: Bool = true) async {
        if reloadFromDisk {
            // Reload local catalog to pick up changes made by external CatalogService instances
            try? await catalogService.load(from: Constants.Paths.resolvedCatalogURL)
        }

        let catalog = await catalogService.currentCatalog()

        // Push to iCloud if enabled
        let iCloudEnabled = await MainActor.run {
            UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")
        }
        if iCloudEnabled, let service = syncService {
            try? await service.pushToICloud()
        }

        // Backup to all external volumes
        let volumeSnapshots = await MainActor.run {
            resolveVolumeSnapshots()
        }
        let volumeErrors = await backupService.backupToVolumes(catalog: catalog, volumes: volumeSnapshots)
        for error in volumeErrors {
            print("[CatalogBackup] Volume: \(error)")
        }

        // Backup to B2 if enabled
        let b2Enabled = await MainActor.run {
            UserDefaults.standard.bool(forKey: "b2Enabled")
        }
        if b2Enabled, let credentials = loadB2Credentials() {
            if let error = await backupService.backupToB2(catalog: catalog, credentials: credentials) {
                print("[CatalogBackup] B2: \(error)")
            }
        }
    }

    /// Restore a catalog from a given source, save it locally, and reload.
    func restoreCatalog(from source: RestoreSource) async throws -> Catalog {
        let catalog: Catalog
        switch source {
        case .volume(let url):
            catalog = try await backupService.restoreFromVolume(volumeURL: url)
        case .b2(let credentials):
            catalog = try await backupService.restoreFromB2(credentials: credentials)
        case .file(let url):
            catalog = try await backupService.restoreFromFile(url: url)
        }

        // Save restored catalog locally
        let catalogURL = Constants.Paths.resolvedCatalogURL
        try await MainActor.run {
            try catalog.save(to: catalogURL)
        }

        // Reload into catalog service
        try await catalogService.load(from: catalogURL)

        // Rebuild SwiftData from the restored catalog so @Query-backed views populate.
        // The catalog is the authoritative source for filename/size/par2/b2/encryption fields;
        // local-only state (storageLocations, perceptualHash, thumbnailState) is preserved when
        // a record already exists and is rediscovered by sync/verify flows otherwise.
        await MainActor.run { hydrateSwiftData(from: catalog) }
        return catalog
    }

    @MainActor
    private func hydrateSwiftData(from catalog: Catalog) {
        guard let container = modelContainer else { return }
        let context = ModelContext(container)

        // Batch-load both models once and match in memory. Fetching per image
        // inside the loop made hydration O(N²) — SwiftData evaluated the
        // #Predicate against every registered record for each lookup, which
        // showed up in Time Profiler as seconds-long main-thread hangs.
        var albumsByKey: [String: AlbumRecord] = [:]
        for album in (try? context.fetch(FetchDescriptor<AlbumRecord>())) ?? [] {
            albumsByKey["\(album.year)/\(album.month)/\(album.day)/\(album.name)"] = album
        }
        var imagesBySHA: [String: ImageRecord] = [:]
        for image in (try? context.fetch(FetchDescriptor<ImageRecord>())) ?? [] {
            imagesBySHA[image.sha256] = image
        }

        var skippedCount = 0

        for (year, yearData) in catalog.years {
            for (month, monthData) in yearData.months {
                for (day, dayData) in monthData.days {
                    for (albumName, catalogAlbum) in dayData.albums {
                        // Reject tampered catalog entries whose path keys would escape the
                        // album directory (path traversal). These keys are joined into
                        // filesystem paths by export/sync/delete/reconcile flows.
                        guard PathComponentValidation.isSafeAlbum(
                            year: year, month: month, day: day, albumName: albumName
                        ) else {
                            skippedCount += catalogAlbum.images.count
                            continue
                        }

                        let albumKey = "\(year)/\(month)/\(day)/\(albumName)"
                        let album: AlbumRecord
                        if let existing = albumsByKey[albumKey] {
                            album = existing
                        } else {
                            album = AlbumRecord(
                                name: albumName,
                                year: year,
                                month: month,
                                day: day,
                                addedAt: catalogAlbum.addedAt
                            )
                            context.insert(album)
                            albumsByKey[albumKey] = album
                        }

                        for catalogImage in catalogAlbum.images {
                            // Skip images whose filename/par2 name would traverse out of
                            // the album directory.
                            guard PathComponentValidation.isSafe(catalogImage.filename),
                                  catalogImage.par2Filename.isEmpty
                                    || PathComponentValidation.isSafe(catalogImage.par2Filename) else {
                                skippedCount += 1
                                continue
                            }
                            let nonce = catalogImage.encryptionNonce.flatMap { Data(base64Encoded: $0) }
                            let isEncrypted = catalogImage.encryptionAlgorithm != nil
                            if let existing = imagesBySHA[catalogImage.sha256] {
                                existing.filename = catalogImage.filename
                                existing.sizeBytes = catalogImage.sizeBytes
                                existing.par2Filename = catalogImage.par2Filename
                                existing.b2FileId = catalogImage.b2FileId
                                existing.isEncrypted = isEncrypted
                                existing.encryptionKeyId = catalogImage.encryptionKeyId
                                existing.encryptionNonce = nonce
                                // Always point the record at the album it lives in per the
                                // catalog being hydrated. Guarding on `album == nil` would
                                // strand the record on a stale album when a restored catalog
                                // re-dates/renames the album (new path → new AlbumRecord),
                                // leaving the new album rendered empty.
                                existing.album = album
                            } else {
                                let record = ImageRecord(
                                    sha256: catalogImage.sha256,
                                    filename: catalogImage.filename,
                                    sizeBytes: catalogImage.sizeBytes,
                                    par2Filename: catalogImage.par2Filename,
                                    b2FileId: catalogImage.b2FileId,
                                    addedAt: catalogAlbum.addedAt,
                                    album: album,
                                    isEncrypted: isEncrypted,
                                    encryptionKeyId: catalogImage.encryptionKeyId,
                                    encryptionNonce: nonce
                                )
                                context.insert(record)
                                imagesBySHA[catalogImage.sha256] = record
                            }
                        }
                    }
                }
            }
        }

        try? context.save()

        if skippedCount > 0 {
            Logger(subsystem: "app.lumivault", category: "sync").warning(
                "Skipped \(skippedCount, privacy: .public) catalog entr\(skippedCount == 1 ? "y" : "ies", privacy: .public) with unsafe path components during hydration."
            )
        }
    }

    enum RestoreSource {
        case volume(URL)
        case b2(B2Credentials)
        case file(URL)
    }

    // MARK: - Catalog Queries

    /// Aggregate image counts per album name from the current catalog.
    func catalogAlbumCounts() async -> [String: Int] {
        await catalogService.albumImageCounts()
    }

    // MARK: - Catalog Mutation (for deletion flows)

    /// Remove an album from the catalog and save.
    func removeAlbumFromCatalog(name: String, year: String, month: String, day: String) async {
        await catalogService.removeAlbum(name: name, year: year, month: month, day: day)
        try? await catalogService.save(to: Constants.Paths.resolvedCatalogURL)
    }

    /// Remove a single image from a catalog album and save.
    func removeImageFromCatalog(sha256: String, albumName: String, year: String, month: String, day: String) async {
        await catalogService.removeImage(sha256: sha256, fromAlbum: albumName, year: year, month: month, day: day)
        try? await catalogService.save(to: Constants.Paths.resolvedCatalogURL)
    }

    /// Update an image's B2 fileId in the catalog and save. Used after the integrity
    /// heal pass re-uploads a file that had gone missing from B2.
    func updateImageB2FileId(sha256: String, b2FileId: String) async {
        await catalogService.updateImageB2FileId(sha256: sha256, b2FileId: b2FileId)
        try? await catalogService.save(to: Constants.Paths.resolvedCatalogURL)
    }

    /// Sync the settings document (import defaults, B2/encryption config, volume
    /// identities). Safe to call often — pushes only when the document content changed.
    /// Views call this after mutating state that lives outside UserDefaults (volumes).
    func syncSettings() async {
        let enabled = await MainActor.run {
            UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")
        }
        guard enabled, isICloudAvailable else { return }

        let localVolumes = await MainActor.run { localVolumeIdentities() }
        do {
            try await settingsSyncService.sync(localVolumes: localVolumes)
        } catch {
            print("[SettingsSync] \(error.localizedDescription)")
        }
    }

    func startMonitoring() async {
        guard let service = syncService else { return }

        // [weak self] must be on the outer closure: an inner-only weak capture
        // conflicts with the outer closure's implicit strong capture of self,
        // which newer Swift toolchains reject outright.
        await service.startMonitoring { [weak self] in
            Task { @MainActor in
                await self?.performSync()
            }
        }
    }

    func stopMonitoring() async {
        await syncService?.stopMonitoring()
    }

    func onSyncToggleChanged(enabled: Bool) async {
        if enabled {
            if isICloudAvailable {
                await performSync()
                await startMonitoring()
            } else {
                await MainActor.run { syncStatus = .error; lastError = "iCloud is not available" }
            }
        } else {
            await stopMonitoring()
            await MainActor.run { syncStatus = .disabled }
        }
    }

    // MARK: - Helpers

    /// One-time migration: relocate `catalog.json` and its `.sha256`/`.par2`/`.vol*.par2` sidecars
    /// from the legacy container path (`~/.lumivault/`) into the user-accessible library
    /// (`~/Pictures/LumiVault/`). No-op when an explicit `catalogPath` override is set, when the
    /// library already has a catalog, or when there's nothing to migrate.
    private func migrateLegacyCatalogIfNeeded() {
        let fm = FileManager.default
        StorageResolver.ensureLibraryExists()

        guard UserDefaults.standard.string(forKey: "catalogPath") == nil else { return }

        let target = Constants.Paths.libraryURL.appendingPathComponent("catalog.json")
        let legacy = Constants.Paths.legacyContainerCatalogURL
        guard !fm.fileExists(atPath: target.path), fm.fileExists(atPath: legacy.path) else { return }

        let legacyDir = legacy.deletingLastPathComponent()
        let targetDir = target.deletingLastPathComponent()
        let names = (try? fm.contentsOfDirectory(atPath: legacyDir.path)) ?? []
        for name in names where name == "catalog.json" || name.hasPrefix("catalog.json.") {
            let to = targetDir.appendingPathComponent(name)
            guard !fm.fileExists(atPath: to.path) else { continue }
            try? fm.moveItem(at: legacyDir.appendingPathComponent(name), to: to)
        }
    }

    /// Resolve all VolumeRecord bookmarks into VolumeSnapshot values.
    /// Must be called on MainActor (accesses SwiftData).
    private func resolveVolumeSnapshots() -> [VolumeSnapshot] {
        guard let container = modelContainer else { return [] }
        let context = ModelContext(container)
        guard let volumes = try? context.fetch(FetchDescriptor<VolumeRecord>()) else { return [] }

        return volumes.compactMap { volume in
            guard let url = try? BookmarkResolver.resolveAndAccess(volume.bookmarkData) else { return nil }
            return VolumeSnapshot(
                volumeID: volume.volumeID,
                label: volume.label,
                mountURL: url
            )
        }
    }

    /// This Mac's registered volumes as identities for the synced settings document.
    /// Must be called on MainActor (accesses SwiftData).
    private func localVolumeIdentities() -> [VolumeIdentity] {
        guard let container = modelContainer else { return [] }
        let context = ModelContext(container)
        guard let volumes = try? context.fetch(FetchDescriptor<VolumeRecord>()) else { return [] }
        return volumes.map { VolumeIdentity(volumeID: $0.volumeID, label: $0.label) }
    }

    private func loadB2Credentials() -> B2Credentials? {
        B2Credentials.load()
    }
}
