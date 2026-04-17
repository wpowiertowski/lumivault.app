import Foundation

/// Distributes catalog.json to all external volumes and optionally to B2.
actor CatalogBackupService {
    private let b2Service = B2Service()

    /// Save catalog.json, its SHA-256 checksum, and PAR2 recovery data to all mounted external volumes.
    /// Uses the top-level `VolumeSnapshot` (from ReconciliationTypes) — mountURL is non-optional.
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

        let checksum = Catalog.sha256Hex(of: data)

        // Generate PAR2 once in a temp directory, collect all companion files
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let tmpCatalog = tmpDir.appendingPathComponent("catalog.json")
        try? data.write(to: tmpCatalog, options: .atomic)
        let redundancy = RedundancyService()
        let par2IndexURL = try? redundancy.generatePAR2(for: tmpCatalog, outputDirectory: tmpDir)
        let par2Files: [URL] = {
            guard let indexURL = par2IndexURL else { return [] }
            return RedundancyService.companionFiles(forIndex: indexURL.lastPathComponent, in: tmpDir)
        }()

        for volume in volumes {
            let mountURL = volume.mountURL
            let destURL = mountURL.appendingPathComponent("catalog.json")
            let checksumURL = mountURL.appendingPathComponent("catalog.json.sha256")
            do {
                try data.write(to: destURL, options: .atomic)
                try checksum.write(to: checksumURL, atomically: true, encoding: .utf8)
                for par2File in par2Files {
                    let dest = mountURL.appendingPathComponent(par2File.lastPathComponent)
                    let fileData = try Data(contentsOf: par2File)
                    try fileData.write(to: dest, options: .atomic)
                }
            } catch {
                errors.append("Failed to save catalog to \(volume.label): \(error.localizedDescription)")
            }

            mountURL.stopAccessingSecurityScopedResource()
        }

        return errors
    }

    /// Upload catalog.json, its SHA-256 sidecar, and PAR2 recovery files to B2.
    /// All uploads flow through `B2Service.uploadImage(fileURL:...)` so they get the same
    /// exponential-backoff retry protection as photo uploads.
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

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            return "Failed to prepare temp directory: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        do {
            // Write catalog to temp file (reused for both upload and PAR2 generation)
            let tmpCatalog = tmpDir.appendingPathComponent("catalog.json")
            try data.write(to: tmpCatalog, options: .atomic)
            let catalogSha256 = Catalog.sha256Hex(of: data)

            _ = try await b2Service.uploadImage(
                fileURL: tmpCatalog,
                remotePath: "catalog.json",
                sha256: catalogSha256,
                credentials: credentials
            )

            // SHA-256 checksum sidecar
            let checksumData = Data(catalogSha256.utf8)
            let tmpChecksum = tmpDir.appendingPathComponent("catalog.json.sha256")
            try checksumData.write(to: tmpChecksum, options: .atomic)
            _ = try await b2Service.uploadImage(
                fileURL: tmpChecksum,
                remotePath: "catalog.json.sha256",
                sha256: Catalog.sha256Hex(of: checksumData),
                credentials: credentials
            )

            // PAR2 recovery data (index + vol files)
            let redundancy = RedundancyService()
            let par2URL = try redundancy.generatePAR2(for: tmpCatalog, outputDirectory: tmpDir)
            let par2Files = RedundancyService.companionFiles(
                forIndex: par2URL.lastPathComponent, in: tmpDir
            )
            for par2File in par2Files {
                let par2Data = try Data(contentsOf: par2File)
                _ = try await b2Service.uploadImage(
                    fileURL: par2File,
                    remotePath: par2File.lastPathComponent,
                    sha256: Catalog.sha256Hex(of: par2Data),
                    credentials: credentials
                )
            }
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
