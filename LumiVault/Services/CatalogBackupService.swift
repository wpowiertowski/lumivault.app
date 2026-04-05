import Foundation
import CryptoKit

/// Distributes catalog.json to all external volumes and optionally to B2.
actor CatalogBackupService {
    private let b2Service = B2Service()

    /// Save catalog.json to all mounted external volumes.
    func backupToVolumes(catalog: Catalog, volumes: [VolumeSnapshot]) async -> [String] {
        var errors: [String] = []

        let data: Data
        do {
            data = try await MainActor.run {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                return try encoder.encode(catalog)
            }
        } catch {
            return ["Failed to encode catalog: \(error.localizedDescription)"]
        }

        for volume in volumes {
            guard let mountURL = volume.mountURL else {
                continue
            }

            let destURL = mountURL.appendingPathComponent("catalog.json")
            do {
                try data.write(to: destURL, options: .atomic)
            } catch {
                errors.append("Failed to save catalog to \(volume.label): \(error.localizedDescription)")
            }

            mountURL.stopAccessingSecurityScopedResource()
        }

        return errors
    }

    /// Upload catalog.json to B2.
    func backupToB2(catalog: Catalog, credentials: B2Credentials) async -> String? {
        let data: Data
        do {
            data = try await MainActor.run {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                return try encoder.encode(catalog)
            }
        } catch {
            return "Failed to encode catalog: \(error.localizedDescription)"
        }

        do {
            try await b2Service.authorize(credentials: credentials)
            try await b2Service.getUploadURL(bucketId: credentials.bucketId)

            let sha1 = sha1Hash(of: data)
            _ = try await b2Service.uploadFile(
                fileData: data,
                fileName: "catalog.json",
                sha1: sha1,
                contentType: "application/json"
            )
            return nil
        } catch {
            return "Failed to upload catalog to B2: \(error.localizedDescription)"
        }
    }

    /// Restore catalog from a volume.
    func restoreFromVolume(volumeURL: URL) async throws -> Catalog {
        let catalogURL = volumeURL.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            throw RestoreError.catalogNotFound(source: volumeURL.lastPathComponent)
        }

        let data = try Data(contentsOf: catalogURL)
        return try await MainActor.run {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Catalog.self, from: data)
        }
    }

    /// Restore catalog from B2.
    func restoreFromB2(credentials: B2Credentials) async throws -> Catalog {
        let data = try await b2Service.downloadFile(
            fileName: "catalog.json",
            bucketId: credentials.bucketId,
            credentials: credentials
        )

        return try await MainActor.run {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Catalog.self, from: data)
        }
    }

    /// Restore catalog from a local file URL.
    func restoreFromFile(url: URL) async throws -> Catalog {
        let data = try Data(contentsOf: url)
        return try await MainActor.run {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Catalog.self, from: data)
        }
    }

    // MARK: - Helpers

    nonisolated private func sha1Hash(of data: Data) -> String {
        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Snapshot of a volume for cross-isolation use.
    struct VolumeSnapshot: Sendable {
        let volumeID: String
        let label: String
        let mountURL: URL?
    }

    enum RestoreError: Error, LocalizedError {
        case catalogNotFound(source: String)

        var errorDescription: String? {
            switch self {
            case .catalogNotFound(let source):
                "No catalog.json found on \(source)."
            }
        }
    }
}
