import Foundation

actor SyncService {
    private let catalogService: CatalogService
    private nonisolated let containerID = Constants.Paths.iCloudContainer
    private let iCloudURL: URL?
    private var isMonitoring = false

    init(catalogService: CatalogService) {
        self.catalogService = catalogService

        // Use the app's iCloud container (hidden from Finder)
        self.iCloudURL = FileManager.default.url(
            forUbiquityContainerIdentifier: containerID
        )?.appendingPathComponent("catalog.json")
    }

    var isICloudAvailable: Bool {
        iCloudURL != nil
    }

    // MARK: - Push (local → iCloud)

    func pushToICloud() async throws {
        guard let url = iCloudURL else { throw SyncError.iCloudUnavailable }

        let catalog = await catalogService.currentCatalog()

        let data = try await MainActor.run {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(catalog)
        }

        // Ensure parent directory exists
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
            try? data.write(to: coordinatedURL, options: .atomic)
        }

        if let error = coordinatorError {
            throw error
        }
    }

    // MARK: - Pull (iCloud → local)

    func pullFromICloud() async throws -> Catalog? {
        guard let url = iCloudURL else { throw SyncError.iCloudUnavailable }

        // Trigger download if file is in iCloud but not local
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var fileData: Data?
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordinatedURL in
            fileData = try? Data(contentsOf: coordinatedURL)
        }

        if let error = coordinatorError {
            throw error
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
            NSString(string: UserDefaults.standard.string(forKey: "catalogPath") ?? Constants.Paths.defaultCatalog).expandingTildeInPath
        }
        try await catalogService.save(to: URL(fileURLWithPath: catalogPath))
    }

    // MARK: - NSMetadataQuery Monitoring

    func startMonitoring(onChange: @escaping @Sendable () -> Void) async {
        guard !isMonitoring, iCloudURL != nil else { return }
        isMonitoring = true

        await MainActor.run {
            MetadataQueryHolder.shared.start(onChange: onChange)
        }
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

    func start(onChange: @escaping @Sendable () -> Void) {
        stop()

        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K == 'catalog.json'", NSMetadataItemFSNameKey)
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { _ in
            onChange()
        }

        query.start()
        self.query = query
    }

    func stop() {
        query?.stop()
        if let q = query {
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: q)
        }
        query = nil
    }
}
