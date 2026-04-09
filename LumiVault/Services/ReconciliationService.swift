import Foundation

actor ReconciliationService {
    private let b2Service = B2Service()
    private let hasher = HasherService()

    // MARK: - Full Reconciliation

    func reconcile(
        snapshots: [ImageSnapshot],
        volumes: [VolumeSnapshot],
        b2Credentials: B2Credentials?,
        verifyHashes: Bool = false,
        progress: ReconciliationProgress
    ) async -> ReconciliationReport {
        var discrepancies: [Discrepancy] = []
        var scannedB2Files = 0

        // Phase 1: Scan volumes (existence check)
        await MainActor.run { progress.phase = .scanningVolumes }
        let volumeResults = await scanVolumes(snapshots: snapshots, volumes: volumes, progress: progress)
        discrepancies.append(contentsOf: volumeResults)

        // Phase 2: Verify file hashes on volumes (optional, slow)
        if verifyHashes {
            await MainActor.run { progress.phase = .verifyingHashes }
            let hashResults = await verifyFileHashes(snapshots: snapshots, volumes: volumes, progress: progress)
            discrepancies.append(contentsOf: hashResults)
        }

        // Phase 3: Scan B2
        if let credentials = b2Credentials {
            await MainActor.run { progress.phase = .scanningB2 }
            do {
                let b2Files = try await b2Service.listAllFiles(
                    bucketId: credentials.bucketId,
                    credentials: credentials
                )
                scannedB2Files = b2Files.count
                let b2Results = Self.diffB2(snapshots: snapshots, b2Files: b2Files)
                discrepancies.append(contentsOf: b2Results)
                await MainActor.run { progress.discrepanciesFound = discrepancies.count }
            } catch {
                // B2 scan failure is non-fatal — report volume results only
            }
        }

        await MainActor.run {
            progress.discrepanciesFound = discrepancies.count
            progress.phase = .complete
        }

        return ReconciliationReport(
            discrepancies: discrepancies,
            scannedImages: snapshots.count,
            scannedVolumes: volumes.count,
            scannedB2Files: scannedB2Files
        )
    }

    // MARK: - Volume Scanning

    private func scanVolumes(
        snapshots: [ImageSnapshot],
        volumes: [VolumeSnapshot],
        progress: ReconciliationProgress
    ) async -> [Discrepancy] {
        var discrepancies: [Discrepancy] = []
        let volumeMap = Dictionary(uniqueKeysWithValues: volumes.map { ($0.volumeID, $0) })

        // Build set of known (volumeID, relativePath) for orphan detection
        var knownPaths: [String: Set<String>] = [:] // volumeID -> set of relativePaths
        for snapshot in snapshots {
            for location in snapshot.storageLocations {
                knownPaths[location.volumeID, default: []].insert(location.relativePath)
            }
        }

        await MainActor.run {
            progress.totalItems = snapshots.count
            progress.processedItems = 0
        }

        // Check each image's declared storage locations
        for (index, snapshot) in snapshots.enumerated() {
            for location in snapshot.storageLocations {
                guard let volume = volumeMap[location.volumeID] else { continue }

                let fileURL = volume.mountURL.appendingPathComponent(location.relativePath)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    discrepancies.append(Discrepancy(
                        sha256: snapshot.sha256,
                        filename: snapshot.filename,
                        kind: .danglingLocation(volumeID: location.volumeID)
                    ))
                }
            }

            await MainActor.run {
                progress.processedItems = index + 1
                progress.discrepanciesFound = discrepancies.count
            }
        }

        // Detect orphans: files on volumes not tracked in any snapshot
        for volume in volumes {
            let orphans = findOrphansOnVolume(mountURL: volume.mountURL, knownPaths: knownPaths[volume.volumeID] ?? [])
            for path in orphans {
                discrepancies.append(Discrepancy(
                    sha256: "",
                    filename: URL(fileURLWithPath: path).lastPathComponent,
                    kind: .orphanOnVolume(volumeID: volume.volumeID, path: path)
                ))
            }
        }

        return discrepancies
    }

    private func findOrphansOnVolume(mountURL: URL, knownPaths: Set<String>) -> [String] {
        var orphans: [String] = []
        let fm = FileManager.default

        // Only scan LumiVault's directory structure (year/month/day/album)
        guard let yearDirs = try? fm.contentsOfDirectory(at: mountURL, includingPropertiesForKeys: nil) else {
            return orphans
        }

        for yearDir in yearDirs {
            guard yearDir.hasDirectoryPath,
                  let monthDirs = try? fm.contentsOfDirectory(at: yearDir, includingPropertiesForKeys: nil) else { continue }

            for monthDir in monthDirs {
                guard monthDir.hasDirectoryPath,
                      let dayDirs = try? fm.contentsOfDirectory(at: monthDir, includingPropertiesForKeys: nil) else { continue }

                for dayDir in dayDirs {
                    guard dayDir.hasDirectoryPath,
                          let albumDirs = try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: nil) else { continue }

                    for albumDir in albumDirs {
                        guard albumDir.hasDirectoryPath,
                              let files = try? fm.contentsOfDirectory(at: albumDir, includingPropertiesForKeys: nil) else { continue }

                        let year = yearDir.lastPathComponent
                        let month = monthDir.lastPathComponent
                        let day = dayDir.lastPathComponent
                        let album = albumDir.lastPathComponent

                        for file in files where !file.hasDirectoryPath {
                            // Skip PAR2 files — they're companion files, not primary images
                            if file.pathExtension == "par2" { continue }

                            let relativePath = "\(year)/\(month)/\(day)/\(album)/\(file.lastPathComponent)"
                            if !knownPaths.contains(relativePath) {
                                orphans.append(relativePath)
                            }
                        }
                    }
                }
            }
        }

        return orphans
    }

    // MARK: - Hash Verification

    private func verifyFileHashes(
        snapshots: [ImageSnapshot],
        volumes: [VolumeSnapshot],
        progress: ReconciliationProgress
    ) async -> [Discrepancy] {
        var discrepancies: [Discrepancy] = []
        let volumeMap = Dictionary(uniqueKeysWithValues: volumes.map { ($0.volumeID, $0) })

        // Count total files to verify for progress
        let totalFiles = snapshots.reduce(0) { $0 + $1.storageLocations.count }
        await MainActor.run {
            progress.totalItems = totalFiles
            progress.processedItems = 0
        }

        var verified = 0
        for snapshot in snapshots {
            for location in snapshot.storageLocations {
                guard let volume = volumeMap[location.volumeID] else {
                    verified += 1
                    continue
                }

                let fileURL = volume.mountURL.appendingPathComponent(location.relativePath)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    if let actualHash = try? await hasher.sha256(of: fileURL),
                       actualHash != snapshot.sha256 {
                        discrepancies.append(Discrepancy(
                            sha256: snapshot.sha256,
                            filename: snapshot.filename,
                            kind: .hashMismatch(
                                volumeID: location.volumeID,
                                expected: snapshot.sha256,
                                actual: actualHash
                            )
                        ))
                    }
                }

                verified += 1
                await MainActor.run {
                    progress.processedItems = verified
                    progress.discrepanciesFound = discrepancies.count
                }
            }
        }

        return discrepancies
    }

    // MARK: - B2 Scanning (pure function for testability)

    nonisolated static func diffB2(
        snapshots: [ImageSnapshot],
        b2Files: [B2FileListing]
    ) -> [Discrepancy] {
        var discrepancies: [Discrepancy] = []

        // Build lookup: fileName -> B2FileListing
        let b2ByName = Dictionary(b2Files.map { ($0.fileName, $0) }, uniquingKeysWith: { _, last in last })

        // Build lookup: b2FileId -> ImageSnapshot
        var snapshotByB2Id: [String: ImageSnapshot] = [:]
        for snapshot in snapshots {
            if let b2Id = snapshot.b2FileId {
                snapshotByB2Id[b2Id] = snapshot
            }
        }

        // Build set of all B2 file IDs referenced by snapshots
        let referencedB2Ids = Set(snapshots.compactMap(\.b2FileId))

        // Check: snapshots with b2FileId that B2 doesn't have
        for snapshot in snapshots {
            guard let b2Id = snapshot.b2FileId else { continue }
            let b2HasById = b2Files.contains { $0.fileId == b2Id }
            if !b2HasById {
                // Also check by path in case fileId changed
                // B2 stores decoded file names, so use the raw unencoded path
                let expectedPath = "\(snapshot.albumPath)/\(snapshot.filename)"
                if b2ByName[expectedPath] == nil {
                    discrepancies.append(Discrepancy(
                        sha256: snapshot.sha256,
                        filename: snapshot.filename,
                        kind: .danglingB2FileId
                    ))
                }
            }
        }

        // Catalog metadata files managed by CatalogBackupService — not image data
        let catalogMetadataFiles: Set<String> = ["catalog.json", "catalog.json.sha256"]

        // Check: B2 files not referenced by any snapshot
        for b2File in b2Files {
            // Skip PAR2 companion files and catalog metadata
            if b2File.fileName.hasSuffix(".par2") { continue }
            if catalogMetadataFiles.contains(b2File.fileName) { continue }

            if !referencedB2Ids.contains(b2File.fileId) {
                discrepancies.append(Discrepancy(
                    sha256: "",
                    filename: b2File.fileName,
                    kind: .orphanInB2(fileId: b2File.fileId, fileName: b2File.fileName)
                ))
            }
        }

        return discrepancies
    }

    // MARK: - Resolution

    func resolve(
        discrepancy: Discrepancy,
        strategy: ResolutionStrategy,
        b2Credentials: B2Credentials?
    ) async throws -> Bool {
        switch strategy {
        case .copyFromVolume(_, let sourceURL):
            // Copy is handled by the caller on MainActor (needs ModelContext for StorageLocation update)
            // This method returns the source data for the caller to write
            return FileManager.default.fileExists(atPath: sourceURL.path)

        case .downloadFromB2(let fileId):
            guard let credentials = b2Credentials else { return false }
            let data = try await b2Service.downloadFile(fileId: fileId, credentials: credentials)
            return !data.isEmpty

        case .uploadToB2:
            // Handled by caller — needs file URL and credentials
            return true

        case .removeDanglingLocation, .updateB2FileId, .ignore:
            // These are metadata-only changes handled by the caller on MainActor
            return true
        }
    }

    func downloadFromB2(fileId: String, credentials: B2Credentials) async throws -> Data {
        try await b2Service.downloadFile(fileId: fileId, credentials: credentials)
    }

    func uploadToB2(fileURL: URL, remotePath: String, sha256: String, credentials: B2Credentials) async throws -> String {
        try await b2Service.uploadImage(fileURL: fileURL, remotePath: remotePath, sha256: sha256, credentials: credentials)
    }
}
