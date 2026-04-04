import Foundation

actor SyncService {
    private let catalogService: CatalogService
    private let iCloudURL: URL?

    init(catalogService: CatalogService) {
        self.catalogService = catalogService

        // iCloud Documents container
        self.iCloudURL = FileManager.default.url(
            forUbiquityContainerIdentifier: nil
        )?.appendingPathComponent("Documents/catalog.json")
    }

    var isICloudAvailable: Bool {
        iCloudURL != nil
    }

    func pushToICloud() async throws {
        guard let url = iCloudURL else { throw SyncError.iCloudUnavailable }

        let catalog = await catalogService.currentCatalog()

        // Encode on MainActor (Codable conformance is MainActor-isolated)
        let data = try await MainActor.run {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(catalog)
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

    func pullFromICloud() async throws -> Catalog? {
        guard let url = iCloudURL else { throw SyncError.iCloudUnavailable }
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

        // Decode on MainActor (Codable conformance is MainActor-isolated)
        let remote = try await MainActor.run {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Catalog.self, from: data)
        }

        let merged = await catalogService.merge(remote: remote)
        return merged
    }

    enum SyncError: Error {
        case iCloudUnavailable
    }
}
