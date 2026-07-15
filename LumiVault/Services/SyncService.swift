import Foundation

actor SyncService {
    private let catalogService: CatalogService
    private nonisolated let containerID = Constants.Paths.iCloudContainer
    private let syncURL: URL
    private let usesICloud: Bool
    private var isMonitoring = false
    /// Serializes the read-merge-write critical sections of `sync()` and
    /// `pushToICloud()` against each other. `SyncService` is an actor, but its
    /// `await` points are reentrancy windows: without this lock a push from a
    /// local mutation could interleave mid-`sync()` and get clobbered by the
    /// stale merged bytes (e.g. resurrecting a just-deleted album).
    private let syncLock = AsyncSemaphore(count: 1)
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

        await syncLock.wait()
        defer { Task { await syncLock.signal() } }

        let catalog = await catalogService.currentCatalog()
        try writeSyncTarget(encodeCatalog(catalog))
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
            var writeError: Error?

            coordinator.coordinate(writingItemAt: syncURL, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
                do {
                    try data.write(to: coordinatedURL, options: .atomic)
                } catch {
                    // Surface the inner write failure. Swallowing it (the old
                    // `try?`) let a disk-full / container error masquerade as a
                    // successful push, so the change was never retried.
                    writeError = error
                }
            }

            if let coordinatorError { throw coordinatorError }
            if let writeError { throw writeError }
        } else {
            try data.write(to: syncURL, options: .atomic)
        }
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
    /// should re-hydrate SwiftData from. Format or timestamp churn that merges
    /// away reports `false`.
    ///
    /// Loop-freedom comes from `merge()` being idempotent and the push/hydrate
    /// decisions using semantic content comparison (`Catalog.contentEquals`)
    /// rather than raw bytes: re-reading our own push yields a merge that is
    /// content-equal to both sides, so nothing is written and no further sync
    /// is triggered.
    @discardableResult
    func sync() async throws -> Bool {
        guard isICloudAvailable else { throw SyncError.iCloudUnavailable }

        await syncLock.wait()
        defer { Task { await syncLock.signal() } }

        let localBefore = await catalogService.currentCatalog()
        let remoteData = try readSyncTarget()

        guard let remoteData else {
            // No remote file yet — seed the sync target with the local catalog.
            try writeSyncTarget(encodeCatalog(localBefore))
            // Materialize catalog.json locally only on a fresh install (no file
            // yet). When it already exists it is byte-identical, so re-saving
            // it (re-encode + SHA-256 + PAR2) would be pure wasted work.
            if !FileManager.default.fileExists(atPath: localCatalogURL.path) {
                try await catalogService.save(to: localCatalogURL)
            }
            return false
        }

        let remote = try decodeCatalog(remoteData)
        let merged = await catalogService.merge(remote: remote)

        // Push when our merged view differs in content from what the target
        // holds. Semantic (not byte) comparison so formatting, key/array order,
        // or a peer's encoder version never masquerade as a real change.
        if !merged.contentEquals(remote) {
            try writeSyncTarget(encodeCatalog(merged))
        }

        // Re-hydrate + persist locally only when the merge changed local
        // content. The save regenerates the .sha256/.par2 sidecars, so it is
        // skipped for a no-op merge.
        let localChanged = !merged.contentEquals(localBefore)
        if localChanged {
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
