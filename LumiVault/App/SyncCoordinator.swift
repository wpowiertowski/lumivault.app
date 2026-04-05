import Foundation
import SwiftUI

/// App-level coordinator that owns the shared CatalogService and SyncService,
/// wires iCloud monitoring, and exposes sync state to SwiftUI views.
@Observable
final class SyncCoordinator: @unchecked Sendable {
    private(set) var syncStatus: SyncStatus = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?
    private(set) var isICloudAvailable: Bool = false

    private let catalogService = CatalogService()
    private var syncService: SyncService?
    private var isSyncing = false

    enum SyncStatus: Sendable {
        case idle, syncing, synced, error, disabled
    }

    // MARK: - Setup

    func setup() async {
        // Load local catalog
        let catalogPath = await MainActor.run {
            NSString(string: UserDefaults.standard.string(forKey: "catalogPath") ?? Constants.Paths.defaultCatalog).expandingTildeInPath
        }
        try? await catalogService.load(from: URL(fileURLWithPath: catalogPath))

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
        guard let service = syncService, !isSyncing else { return }
        isSyncing = true

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

        isSyncing = false
    }

    /// Push local catalog to iCloud after a local mutation (export, delete, etc.).
    func pushAfterLocalChange() async {
        let enabled = await MainActor.run {
            UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")
        }
        guard enabled, let service = syncService else { return }

        // Reload local catalog to pick up the latest changes
        let catalogPath = await MainActor.run {
            NSString(string: UserDefaults.standard.string(forKey: "catalogPath") ?? Constants.Paths.defaultCatalog).expandingTildeInPath
        }
        try? await catalogService.load(from: URL(fileURLWithPath: catalogPath))

        try? await service.pushToICloud()
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
}
