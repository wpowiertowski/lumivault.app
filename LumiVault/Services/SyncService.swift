import Foundation

actor SyncService {
    private let catalogService: CatalogService
    private nonisolated let containerID = Constants.Paths.iCloudContainer
    private let syncURL: URL
    private let usesICloud: Bool
    private var isMonitoring = false

    init(catalogService: CatalogService) {
        self.catalogService = catalogService

        if let iCloudURL = FileManager.default.url(
            forUbiquityContainerIdentifier: containerID
        )?.appendingPathComponent("catalog.json") {
            self.syncURL = iCloudURL
            self.usesICloud = true
        } else {
            #if DEBUG
            // Fall back to local directory when iCloud is unavailable (e.g. no provisioning profile)
            let fallbackPath = PlatformHelpers.expandTilde(Constants.Paths.debugSyncFallback)
            self.syncURL = URL(fileURLWithPath: fallbackPath)
            self.usesICloud = false
            #else
            // In release, set a dummy URL — isICloudAvailable will be false
            self.syncURL = URL(fileURLWithPath: "/dev/null")
            self.usesICloud = false
            #endif
        }
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

    // MARK: - Push (local → sync target)

    func pushToICloud() async throws {
        guard isICloudAvailable else { throw SyncError.iCloudUnavailable }

        let catalog = await catalogService.currentCatalog()

        let data = try await MainActor.run {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(catalog)
        }

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
    }

    // MARK: - Pull (sync target → local)

    func pullFromICloud() async throws -> Catalog? {
        guard isICloudAvailable else { throw SyncError.iCloudUnavailable }

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

        guard let data = fileData else { return nil }

        let remote = try await MainActor.run {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Catalog.self, from: data)
        }

        let merged = await catalogService.merge(remote: remote)
        return merged
    }

    // MARK: - Sync (pull then push)

    func sync() async throws {
        _ = try await pullFromICloud()

        // After merging remote changes, push the merged result back
        try await pushToICloud()

        // Also save merged catalog locally
        let catalogPath = await MainActor.run {
            PlatformHelpers.expandTilde(UserDefaults.standard.string(forKey: "catalogPath") ?? Constants.Paths.defaultCatalog)
        }
        try await catalogService.save(to: URL(fileURLWithPath: catalogPath))
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
        query.predicate = NSPredicate(format: "%K == 'catalog.json'", NSMetadataItemFSNameKey)
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
