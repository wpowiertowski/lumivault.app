import Foundation
import SwiftUI
import SwiftData

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
    private var isSyncing = false
    var modelContainer: ModelContainer?

    enum SyncStatus: Sendable {
        case idle, syncing, synced, error, disabled
    }

    // MARK: - Setup

    func setup() async {
        // Load local catalog
        let catalogPath = await MainActor.run {
            NSString(string: UserDefaults.standard.string(forKey: "catalogPath") ?? Constants.Paths.defaultCatalog).expandingTildeInPath
        }
        let catalogURL = URL(fileURLWithPath: catalogPath)

        // Verify catalog integrity before loading
        if FileManager.default.fileExists(atPath: catalogPath) {
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
    }

    // MARK: - Public API

    func performSync() async {
        let alreadySyncing = await MainActor.run { isSyncing }
        guard let service = syncService, !alreadySyncing else { return }
        await MainActor.run { isSyncing = true }

        await MainActor.run {
            syncStatus = .syncing
            lastError = nil
        }

        do {
            try await service.sync()
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
            let catalogPath = await MainActor.run {
                NSString(string: UserDefaults.standard.string(forKey: "catalogPath") ?? Constants.Paths.defaultCatalog).expandingTildeInPath
            }
            try? await catalogService.load(from: URL(fileURLWithPath: catalogPath))
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
        let catalogPath = await MainActor.run {
            NSString(string: UserDefaults.standard.string(forKey: "catalogPath") ?? Constants.Paths.defaultCatalog).expandingTildeInPath
        }
        let catalogURL = URL(fileURLWithPath: catalogPath)
        try await MainActor.run {
            try catalog.save(to: catalogURL)
        }

        // Reload into catalog service
        try await catalogService.load(from: catalogURL)
        return catalog
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
        let catalogPath = await MainActor.run {
            NSString(string: UserDefaults.standard.string(forKey: "catalogPath") ?? Constants.Paths.defaultCatalog).expandingTildeInPath
        }
        try? await catalogService.save(to: URL(fileURLWithPath: catalogPath))
    }

    /// Remove a single image from a catalog album and save.
    func removeImageFromCatalog(sha256: String, albumName: String, year: String, month: String, day: String) async {
        await catalogService.removeImage(sha256: sha256, fromAlbum: albumName, year: year, month: month, day: day)
        let catalogPath = await MainActor.run {
            NSString(string: UserDefaults.standard.string(forKey: "catalogPath") ?? Constants.Paths.defaultCatalog).expandingTildeInPath
        }
        try? await catalogService.save(to: URL(fileURLWithPath: catalogPath))
    }

    func startMonitoring() async {
        guard let service = syncService else { return }

        await service.startMonitoring {
            Task { @MainActor [weak self] in
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

    /// Resolve all VolumeRecord bookmarks into CatalogBackupService.VolumeSnapshot values.
    /// Must be called on MainActor (accesses SwiftData).
    private func resolveVolumeSnapshots() -> [CatalogBackupService.VolumeSnapshot] {
        guard let container = modelContainer else { return [] }
        let context = ModelContext(container)
        guard let volumes = try? context.fetch(FetchDescriptor<VolumeRecord>()) else { return [] }

        return volumes.compactMap { volume in
            guard let url = try? BookmarkResolver.resolveAndAccess(volume.bookmarkData) else { return nil }
            return CatalogBackupService.VolumeSnapshot(
                volumeID: volume.volumeID,
                label: volume.label,
                mountURL: url
            )
        }
    }

    private func loadB2Credentials() -> B2Credentials? {
        guard let data = UserDefaults.standard.data(forKey: B2Credentials.defaultsKey),
              let credentials = try? JSONDecoder().decode(B2Credentials.self, from: data) else { return nil }
        return credentials
    }
}
