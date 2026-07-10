import Foundation
import CryptoKit

actor ReconciliationService {
    private let b2Service = B2Service()
    private let hasher = HasherService()

    // The local library is included as a `VolumeSnapshot` by the production call sites (the
    // Integrity views) via `StorageResolver.librarySnapshot()`, so this service stays a pure
    // function of its inputs and unit tests never touch the real `~/Pictures/LumiVault`.

    // MARK: - Full Reconciliation

    func reconcile(
        snapshots: [ImageSnapshot],
        volumes: [VolumeSnapshot],
        b2Credentials: B2Credentials?,
        verifyHashes: Bool = false,
        scanOrphans: Bool = true,
        progress: ReconciliationProgress
    ) async -> ReconciliationReport {
        var discrepancies: [Discrepancy] = []
        var scannedB2Files = 0

        // Phase 1: Scan volumes (existence check)
        await MainActor.run { progress.phase = .scanningVolumes }
        let volumeResults = await scanVolumes(snapshots: snapshots, volumes: volumes, scanOrphans: scanOrphans, progress: progress)
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
        scanOrphans: Bool,
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
        // Skip when verifying a subset of images (e.g. single image or album)
        if scanOrphans {
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

    // MARK: - Repair

    func repairCorruptedFiles(
        discrepancies: [Discrepancy],
        snapshots: [ImageSnapshot],
        volumes: [VolumeSnapshot],
        progress: ReconciliationProgress
    ) async -> [RepairResult] {
        let hashMismatches = discrepancies.filter {
            if case .hashMismatch = $0.kind { return true }
            return false
        }

        guard !hashMismatches.isEmpty else { return [] }

        await MainActor.run {
            progress.phase = .repairing
            progress.totalItems = hashMismatches.count
            progress.processedItems = 0
        }

        let snapshotsByHash = Dictionary(snapshots.map { ($0.sha256, $0) }, uniquingKeysWith: { first, _ in first })
        let volumeMap = Dictionary(uniqueKeysWithValues: volumes.map { ($0.volumeID, $0) })
        let redundancy = RedundancyService()
        var results: [RepairResult] = []

        for (index, discrepancy) in hashMismatches.enumerated() {
            guard case .hashMismatch(let corruptedVolumeID, let expectedHash, _) = discrepancy.kind,
                  let corruptedVolume = volumeMap[corruptedVolumeID],
                  let snapshot = snapshotsByHash[discrepancy.sha256] else {
                results.append(RepairResult(
                    sha256: discrepancy.sha256,
                    filename: discrepancy.filename,
                    volumeID: "",
                    outcome: .failed("Missing snapshot or volume data")
                ))
                await MainActor.run { progress.processedItems = index + 1 }
                continue
            }

            // Find the corrupted file's relative path on the volume
            let corruptedLocation = snapshot.storageLocations.first { $0.volumeID == corruptedVolumeID }
            guard let relativePath = corruptedLocation?.relativePath else {
                results.append(RepairResult(
                    sha256: discrepancy.sha256,
                    filename: discrepancy.filename,
                    volumeID: corruptedVolumeID,
                    outcome: .failed("No storage location found for volume")
                ))
                await MainActor.run { progress.processedItems = index + 1 }
                continue
            }

            let corruptedURL = corruptedVolume.mountURL.appendingPathComponent(relativePath)

            // Defense in depth: a repair writes to corruptedURL; refuse if a tampered
            // catalog's relativePath resolves outside the volume root.
            guard corruptedURL.isDescendant(of: corruptedVolume.mountURL) else {
                results.append(RepairResult(
                    sha256: discrepancy.sha256,
                    filename: discrepancy.filename,
                    volumeID: corruptedVolumeID,
                    outcome: .failed("Storage path resolves outside the volume")
                ))
                await MainActor.run { progress.processedItems = index + 1 }
                continue
            }

            // Strategy 1: Copy from a healthy volume
            var repaired = false
            for location in snapshot.storageLocations where location.volumeID != corruptedVolumeID {
                guard let sourceVolume = volumeMap[location.volumeID] else { continue }
                let sourceURL = sourceVolume.mountURL.appendingPathComponent(location.relativePath)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }

                // Verify the source is actually healthy
                guard let sourceHash = try? await hasher.sha256(of: sourceURL),
                      sourceHash == expectedHash else { continue }

                // Replace corrupted file with healthy copy
                do {
                    let data = try Data(contentsOf: sourceURL)
                    try data.write(to: corruptedURL, options: .atomic)
                    results.append(RepairResult(
                        sha256: discrepancy.sha256,
                        filename: discrepancy.filename,
                        volumeID: corruptedVolumeID,
                        outcome: .copiedFromVolume(location.volumeID)
                    ))
                    repaired = true
                    break
                } catch {
                    continue
                }
            }

            // Strategy 2: PAR2 repair
            if !repaired && !snapshot.par2Filename.isEmpty {
                let par2URL = corruptedURL.deletingLastPathComponent()
                    .appendingPathComponent(snapshot.par2Filename)

                if FileManager.default.fileExists(atPath: par2URL.path) {
                    do {
                        if let repairedData = try redundancy.repair(
                            par2URL: par2URL,
                            corruptedFileURL: corruptedURL
                        ) {
                            try repairedData.write(to: corruptedURL, options: .atomic)
                            results.append(RepairResult(
                                sha256: discrepancy.sha256,
                                filename: discrepancy.filename,
                                volumeID: corruptedVolumeID,
                                outcome: .repairedViaPAR2
                            ))
                            repaired = true
                        }
                    } catch {
                        // PAR2 repair failed — fall through to unrecoverable
                    }
                }
            }

            if !repaired {
                results.append(RepairResult(
                    sha256: discrepancy.sha256,
                    filename: discrepancy.filename,
                    volumeID: corruptedVolumeID,
                    outcome: .failed("No healthy copy available and PAR2 repair failed")
                ))
            }

            await MainActor.run { progress.processedItems = index + 1 }
        }

        return results
    }

    // MARK: - Heal (restore missing replicas across storage targets)

    /// Restore files that are present in one storage target but missing from
    /// another, fanning each recovered file back out so every target that should
    /// hold it does. Handles `.danglingLocation` (missing from a volume) and
    /// `.danglingB2FileId` (missing from B2). This is pure file I/O + B2; the only
    /// catalog mutation needed — a new B2 fileId after re-upload — is handed back to
    /// the caller via `.restoredToB2(newFileId:)` for an on-MainActor write-back.
    func healReplicas(
        discrepancies: [Discrepancy],
        snapshots: [ImageSnapshot],
        volumes: [VolumeSnapshot],
        b2Credentials: B2Credentials?,
        progress: ReconciliationProgress
    ) async -> [HealResult] {
        let healable = discrepancies.filter {
            switch $0.kind {
            case .danglingLocation, .danglingB2FileId: return true
            default: return false
            }
        }
        guard !healable.isEmpty else { return [] }

        await MainActor.run {
            progress.phase = .healing
            progress.totalItems = healable.count
            progress.processedItems = 0
        }

        let snapshotsByHash = Dictionary(snapshots.map { ($0.sha256, $0) }, uniquingKeysWith: { first, _ in first })
        let volumeMap = Dictionary(uniqueKeysWithValues: volumes.map { ($0.volumeID, $0) })
        var results: [HealResult] = []

        for (index, discrepancy) in healable.enumerated() {
            if let snapshot = snapshotsByHash[discrepancy.sha256] {
                switch discrepancy.kind {
                case .danglingLocation(let volumeID):
                    results.append(await healVolume(volumeID: volumeID, snapshot: snapshot, volumeMap: volumeMap, b2Credentials: b2Credentials))
                case .danglingB2FileId:
                    results.append(await healB2(snapshot: snapshot, volumeMap: volumeMap, b2Credentials: b2Credentials))
                default:
                    break
                }
            } else {
                results.append(HealResult(sha256: discrepancy.sha256, filename: discrepancy.filename, outcome: .failed("No catalog entry for image")))
            }
            await MainActor.run { progress.processedItems = index + 1 }
        }

        return results
    }

    /// Restore a file missing from `targetVolumeID` — from a healthy sibling
    /// volume if one holds it, otherwise by downloading from B2.
    private func healVolume(
        volumeID targetVolumeID: String,
        snapshot: ImageSnapshot,
        volumeMap: [String: VolumeSnapshot],
        b2Credentials: B2Credentials?
    ) async -> HealResult {
        func fail(_ reason: String) -> HealResult {
            HealResult(sha256: snapshot.sha256, filename: snapshot.filename, outcome: .failed(reason))
        }

        guard let targetVolume = volumeMap[targetVolumeID] else {
            return fail("Target volume not connected")
        }
        guard let targetLocation = snapshot.storageLocations.first(where: { $0.volumeID == targetVolumeID }) else {
            return fail("No recorded path for target volume")
        }
        let targetURL = targetVolume.mountURL.appendingPathComponent(targetLocation.relativePath)
        // Defense in depth: a tampered catalog relativePath must not write outside the volume.
        guard targetURL.isDescendant(of: targetVolume.mountURL) else {
            return fail("Storage path resolves outside the volume")
        }
        let targetDir = targetURL.deletingLastPathComponent()

        // Source 1: a sibling volume that already holds the file.
        for location in snapshot.storageLocations where location.volumeID != targetVolumeID {
            guard let sourceVolume = volumeMap[location.volumeID] else { continue }
            let sourceURL = sourceVolume.mountURL.appendingPathComponent(location.relativePath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
            if !snapshot.isEncrypted {
                guard let sourceHash = try? await hasher.sha256(of: sourceURL),
                      sourceHash == snapshot.sha256 else { continue }
            }
            do {
                try Self.writeAtomicCopy(from: sourceURL, to: targetURL)
                Self.restorePAR2BetweenVolumes(snapshot: snapshot, sourceDir: sourceURL.deletingLastPathComponent(), targetDir: targetDir)
                return HealResult(sha256: snapshot.sha256, filename: snapshot.filename, outcome: .restoredToVolume(volumeID: targetVolumeID, source: .volume(location.volumeID)))
            } catch { continue }
        }

        // Source 2: B2. Stored bytes mirror the on-volume representation (ciphertext
        // when encrypted), so they can be written straight to the volume path.
        if let credentials = b2Credentials, let fileId = snapshot.b2FileId {
            do {
                let data = try await b2Service.downloadFile(fileId: fileId, credentials: credentials)
                if !snapshot.isEncrypted, Self.hexSHA256(data) != snapshot.sha256 {
                    return fail("B2 copy failed integrity check")
                }
                try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
                try data.write(to: targetURL, options: .atomic)
                await restorePAR2FromB2(snapshot: snapshot, targetDir: targetDir, credentials: credentials)
                return HealResult(sha256: snapshot.sha256, filename: snapshot.filename, outcome: .restoredToVolume(volumeID: targetVolumeID, source: .b2))
            } catch {
                return fail("B2 restore failed: \(error.localizedDescription)")
            }
        }

        return fail("No healthy source available")
    }

    /// Restore a file missing from B2 by re-uploading from a healthy local replica.
    private func healB2(
        snapshot: ImageSnapshot,
        volumeMap: [String: VolumeSnapshot],
        b2Credentials: B2Credentials?
    ) async -> HealResult {
        func fail(_ reason: String) -> HealResult {
            HealResult(sha256: snapshot.sha256, filename: snapshot.filename, outcome: .failed(reason))
        }
        guard let credentials = b2Credentials else { return fail("B2 not configured") }

        for location in snapshot.storageLocations {
            guard let sourceVolume = volumeMap[location.volumeID] else { continue }
            let sourceURL = sourceVolume.mountURL.appendingPathComponent(location.relativePath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
            if !snapshot.isEncrypted {
                guard let sourceHash = try? await hasher.sha256(of: sourceURL),
                      sourceHash == snapshot.sha256 else { continue }
            }
            do {
                let remotePath = "\(snapshot.albumPath)/\(snapshot.filename)"
                let newFileId = try await b2Service.uploadImage(
                    fileURL: sourceURL,
                    remotePath: remotePath,
                    sha256: snapshot.sha256,
                    credentials: credentials
                )
                await uploadPAR2ToB2(snapshot: snapshot, sourceDir: sourceURL.deletingLastPathComponent(), credentials: credentials)
                return HealResult(sha256: snapshot.sha256, filename: snapshot.filename, outcome: .restoredToB2(newFileId: newFileId, source: .volume(location.volumeID)))
            } catch { continue }
        }
        return fail("No healthy local replica to re-upload")
    }

    // MARK: - Heal helpers

    private nonisolated static func writeAtomicCopy(from source: URL, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Data(contentsOf: source)
        try data.write(to: dest, options: .atomic)
    }

    private nonisolated static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Mirror PAR2 companions from a healthy volume dir into the target volume dir.
    private nonisolated static func restorePAR2BetweenVolumes(snapshot: ImageSnapshot, sourceDir: URL, targetDir: URL) {
        let indexName = snapshot.par2Filename.isEmpty ? snapshot.filename + ".par2" : snapshot.par2Filename
        let fm = FileManager.default
        for companion in RedundancyService.companionFiles(forIndex: indexName, in: sourceDir) {
            let dest = targetDir.appendingPathComponent(companion.lastPathComponent)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            try? fm.copyItem(at: companion, to: dest)
        }
    }

    /// Download PAR2 companions for `snapshot` from B2 into `targetDir`.
    private func restorePAR2FromB2(snapshot: ImageSnapshot, targetDir: URL, credentials: B2Credentials) async {
        let indexName = snapshot.par2Filename.isEmpty ? snapshot.filename + ".par2" : snapshot.par2Filename
        let baseName = String(indexName.dropLast(5)) // drop ".par2"
        let prefix = "\(snapshot.albumPath)/\(baseName)"
        guard let listings = try? await b2Service.listAllFiles(bucketId: credentials.bucketId, credentials: credentials, prefix: prefix) else { return }
        let fm = FileManager.default
        for listing in listings {
            let name = listing.fileName.split(separator: "/").last.map(String.init) ?? listing.fileName
            let isIndex = name == indexName
            let isVol = name.hasPrefix(baseName + ".vol") && name.hasSuffix(".par2")
            guard isIndex || isVol else { continue }
            let dest = targetDir.appendingPathComponent(name)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            if let data = try? await b2Service.downloadFile(fileId: listing.fileId, credentials: credentials) {
                try? data.write(to: dest, options: .atomic)
            }
        }
    }

    /// Re-upload PAR2 companions for `snapshot` from a local volume dir to B2.
    private func uploadPAR2ToB2(snapshot: ImageSnapshot, sourceDir: URL, credentials: B2Credentials) async {
        let indexName = snapshot.par2Filename.isEmpty ? snapshot.filename + ".par2" : snapshot.par2Filename
        for companion in RedundancyService.companionFiles(forIndex: indexName, in: sourceDir) {
            let remoteName = "\(snapshot.albumPath)/\(companion.lastPathComponent)"
            if let exists = try? await b2Service.fileExists(fileName: remoteName, bucketId: credentials.bucketId, credentials: credentials), exists {
                continue
            }
            _ = try? await b2Service.uploadImage(fileURL: companion, remotePath: remoteName, sha256: "", credentials: credentials)
        }
    }
}
