import Foundation

actor SyncService {
    private let catalogService: CatalogService
    private nonisolated let containerID = Constants.Paths.iCloudContainer
    private let syncURL: URL
    private let usesICloud: Bool
    private var isMonitoring = false
    /// Bytes of the last catalog.json this process wrote to the sync target.
    /// The NSMetadataQuery watching the container fires for our own writes
    /// (and again for each upload-state transition); comparing against these
    /// bytes lets `sync()` recognize such echoes and return without doing the
    /// pull-merge-push cycle. Without this, every sync re-triggered another
    /// sync ~2s later — an endless loop of main-thread catalog work.
    private var lastPushedData: Data?
    /// Where `sync()` saves the merged catalog locally. Injectable so unit
    /// tests never touch the real `~/Pictures/LumiVault/catalog.json`.
    private let localCatalogURL: URL

    init(catalogService: CatalogService) {
        self.catalogService = catalogService
        self.localCatalogURL = Constants.Paths.resolvedCatalogURL

        if let iCloudURL = FileManager.default.url(
            forUbiquityContainerIdentifier: containerID
        )?.appendingPathComponent("catalog.json") {
            self.syncURL = iCloudURL
            self.usesICloud = true
        } else {
            #if DEBUG
            // Fall back to the local catalog location when iCloud is unavailable (e.g. no provisioning profile)
            self.syncURL = Constants.Paths.resolvedCatalogURL
            self.usesICloud = false
            #else
            // In release, set a dummy URL — isICloudAvailable will be false
            self.syncURL = URL(fileURLWithPath: "/dev/null")
            self.usesICloud = false
            #endif
        }
    }

    /// Test-only initializer that points at an explicit file URL and bypasses
    /// NSFileCoordinator. Lets unit tests exercise push/pull/merge against a temp
    /// directory without requiring an iCloud entitlement.
    init(catalogService: CatalogService, syncURL: URL) {
        self.catalogService = catalogService
        self.syncURL = syncURL
        self.usesICloud = false
        self.localCatalogURL = syncURL
            .deletingLastPathComponent()
            .appendingPathComponent("local-catalog.json")
    }

    var isICloudAvailable: Bool {
        usesICloud || isDebugFallbackAvailable
    }

    private var isDebugFallbackAvailable: Bool {
        #if DEBUG
        return !usesICloud
        #else
        return false
        #endif
    }

    // MARK: - Encoding

    // Catalog is nonisolated, so encode/decode run on this actor's executor —
    // a full-catalog encode used to hang the main thread for hundreds of ms.
    private func encodeCatalog(_ catalog: Catalog) throws -> Data {
        let encoder = JSONEncoder()
        // sortedKeys keeps the output deterministic so byte comparisons
        // ("did the merge change anything?") are meaningful. prettyPrinted
        // was dropped — it inflated encode time and file size for a
        // machine-consumed file.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(catalog)
    }

    private func decodeCatalog(_ data: Data) throws -> Catalog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Catalog.self, from: data)
    }

    // MARK: - Push (local → sync target)

    func pushToICloud() async throws {
        guard isICloudAvailable else { throw SyncError.iCloudUnavailable }

        let catalog = await catalogService.currentCatalog()
        let data = try encodeCatalog(catalog)

        // Skip the write when the sync target already holds these exact
        // bytes — every write re-triggers the metadata query watching the
        // container.
        if data == lastPushedData { return }
        try writeSyncTarget(data)
    }

    private func writeSyncTarget(_ data: Data) throws {
        // Ensure parent directory exists
        let dir = syncURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if usesICloud {
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?

            coordinator.coordinate(writingItemAt: syncURL, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
                try? data.write(to: coordinatedURL, options: .atomic)
            }

            if let error = coordinatorError {
                throw error
            }
        } else {
            try data.write(to: syncURL, options: .atomic)
        }
        lastPushedData = data
    }

    // MARK: - Pull (sync target → local)

    private func readSyncTarget() throws -> Data? {
        if usesICloud {
            // Trigger download if file is in iCloud but not local
            try? FileManager.default.startDownloadingUbiquitousItem(at: syncURL)
        }

        guard FileManager.default.fileExists(atPath: syncURL.path) else { return nil }

        var fileData: Data?

        if usesICloud {
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?

            coordinator.coordinate(readingItemAt: syncURL, options: [], error: &coordinatorError) { coordinatedURL in
                fileData = try? Data(contentsOf: coordinatedURL)
            }

            if let error = coordinatorError {
                throw error
            }
        } else {
            fileData = try? Data(contentsOf: syncURL)
        }

        return fileData
    }

    func pullFromICloud() async throws -> Catalog? {
        guard isICloudAvailable else { throw SyncError.iCloudUnavailable }

        guard let data = try readSyncTarget() else { return nil }
        let remote = try decodeCatalog(data)
        return await catalogService.merge(remote: remote)
    }

    // MARK: - Sync (pull, merge, push-if-changed)

    /// Pull-merge-push. Returns `true` when the merge actually changed the
    /// local catalog — i.e. content arrived from another Mac that the caller
    /// should re-hydrate SwiftData from. Byte differences that merge away
    /// (format or timestamp churn from another Mac) report `false`.
    ///
    /// Pushes only when the merge produced bytes that differ from the sync
    /// target, and recognizes metadata-query echoes of our own writes, so a
    /// sync can never re-trigger itself through the query watching the
    /// container.
    @discardableResult
    func sync() async throws -> Bool {
        guard isICloudAvailable else { throw SyncError.iCloudUnavailable }

        let remoteData = try readSyncTarget()

        // Echo of our own last push — nothing new from other Macs.
        if let remoteData, remoteData == lastPushedData {
            return false
        }

        guard let remoteData else {
            // No remote file yet — seed the sync target with the local catalog.
            try await pushToICloud()
            try await catalogService.save(to: localCatalogURL)
            return false
        }

        let localData = try encodeCatalog(await catalogService.currentCatalog())
        let remote = try decodeCatalog(remoteData)
        let merged = await catalogService.merge(remote: remote)
        let mergedData = try encodeCatalog(merged)

        if mergedData != remoteData {
            try writeSyncTarget(mergedData)
        } else {
            // The target already equals the merge result; remember its bytes
            // so the next metadata event for this content reads as settled.
            lastPushedData = remoteData
        }

        let localChanged = mergedData != localData
        if localChanged {
            // Save the merged catalog locally (outside the watched container).
            // Skipped when the merge was a no-op — the save regenerates the
            // .sha256/.par2 sidecars, which is pointless work for unchanged
            // content.
            try await catalogService.save(to: localCatalogURL)
        }
        return localChanged
    }

    // MARK: - NSMetadataQuery Monitoring

    func startMonitoring(onChange: @escaping @Sendable () -> Void) async {
        guard !isMonitoring else { return }

        if usesICloud {
            isMonitoring = true
            await MainActor.run {
                MetadataQueryHolder.shared.start(onChange: onChange)
            }
        }
        // No monitoring needed for local debug fallback
    }

    func stopMonitoring() async {
        guard isMonitoring else { return }
        isMonitoring = false

        await MainActor.run {
            MetadataQueryHolder.shared.stop()
        }
    }

    // MARK: - Errors

    enum SyncError: Error, LocalizedError {
        case iCloudUnavailable

        var errorDescription: String? {
            switch self {
            case .iCloudUnavailable: "iCloud is not available. Sign in to iCloud in System Settings."
            }
        }
    }
}

// MARK: - MainActor query holder

/// Holds NSMetadataQuery on MainActor since it requires main thread access.
@MainActor
final class MetadataQueryHolder {
    static let shared = MetadataQueryHolder()
    private var query: NSMetadataQuery?
    private var debounceTask: Task<Void, Never>?

    func start(onChange: @escaping @Sendable () -> Void) {
        stop()

        let query = NSMetadataQuery()
        // settings.json shares the container and the same change-driven sync cycle.
        query.predicate = NSPredicate(
            format: "%K IN %@", NSMetadataItemFSNameKey, ["catalog.json", "settings.json"]
        )
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.debounceTask?.cancel()
                self?.debounceTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    onChange()
                }
            }
        }

        query.start()
        self.query = query
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        query?.stop()
        if let q = query {
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: q)
        }
        query = nil
    }
}
