import Foundation
import SwiftData

@Observable
final class DeletionProgress: @unchecked Sendable {
    var phase: DeletionPhase = .idle
    var totalItems: Int = 0
    var processedItems: Int = 0
    var errors: [String] = []

    var fraction: Double {
        guard totalItems > 0 else { return 0 }
        return Double(processedItems) / Double(totalItems)
    }
}

enum DeletionPhase: String, Sendable {
    case idle = "Idle"
    case removingFromVolumes = "Removing from volumes"
    case removingFromB2 = "Removing from B2"
    case updatingCatalog = "Updating catalog"
    case complete = "Complete"
}

actor DeletionService {
    private let b2Service = B2Service()

    struct ImageDeletionInput: Sendable {
        let sha256: String
        let filename: String
        let par2Filename: String
        let b2FileId: String?
        let storageLocations: [StorageLocation]
        let albumPath: String
    }

    struct DeletionResult: Sendable {
        var volumeFilesRemoved: Int = 0
        var b2FilesRemoved: Int = 0
        var errors: [String] = []

        nonisolated init(volumeFilesRemoved: Int = 0, b2FilesRemoved: Int = 0, errors: [String] = []) {
            self.volumeFilesRemoved = volumeFilesRemoved
            self.b2FilesRemoved = b2FilesRemoved
            self.errors = errors
        }
    }

    /// Delete image files from all external volumes and B2.
    func deleteImageFiles(
        images: [ImageDeletionInput],
        mountedVolumes: [(volumeID: String, mountURL: URL)],
        b2Credentials: B2Credentials?,
        progress: DeletionProgress
    ) async -> DeletionResult {
        var result = DeletionResult()
        let fm = FileManager.default

        // Phase 1: Remove from volumes
        await MainActor.run { progress.phase = .removingFromVolumes }
        let totalVolumeOps = images.reduce(0) { $0 + $1.storageLocations.count }
        await MainActor.run { progress.totalItems = totalVolumeOps + (b2Credentials != nil ? images.count : 0) }

        for image in images {
            for location in image.storageLocations {
                guard let (_, mountURL) = mountedVolumes.first(where: { $0.volumeID == location.volumeID }) else {
                    continue
                }

                let filePath = mountURL.appendingPathComponent(location.relativePath)
                do {
                    if fm.fileExists(atPath: filePath.path) {
                        try fm.removeItem(at: filePath)
                        result.volumeFilesRemoved += 1
                    }

                    // Also remove PAR2 companion files (index + vol)
                    if !image.par2Filename.isEmpty {
                        let dir = filePath.deletingLastPathComponent()
                        let companions = RedundancyService.companionFiles(
                            forIndex: image.par2Filename, in: dir
                        )
                        for companion in companions {
                            if fm.fileExists(atPath: companion.path) {
                                try fm.removeItem(at: companion)
                            }
                        }
                    }

                    // Clean up empty directories up to volume root
                    Self.removeEmptyAncestors(
                        from: filePath.deletingLastPathComponent(),
                        stopAt: mountURL,
                        fileManager: fm
                    )
                } catch {
                    result.errors.append("Volume remove failed: \(image.filename) on \(location.volumeID) — \(error.localizedDescription)")
                }

                await MainActor.run { progress.processedItems += 1 }
            }
        }

        // Phase 2: Remove from B2
        if let credentials = b2Credentials {
            await MainActor.run { progress.phase = .removingFromB2 }

            for image in images {
                if let fileId = image.b2FileId, !fileId.isEmpty {
                    // B2 stores decoded file names (it decodes the percent-encoded
                    // X-Bz-File-Name header on upload). Use the raw unencoded path
                    // for listing prefix, comparison, and deletion.
                    let remotePath = "\(image.albumPath)/\(image.filename)"

                    // Look up current file version by name — stored fileId may be stale
                    do {
                        let listings = try await b2Service.listAllFiles(
                            bucketId: credentials.bucketId,
                            credentials: credentials,
                            prefix: remotePath
                        )
                        if let listing = listings.first(where: { $0.fileName == remotePath }) {
                            try await b2Service.deleteFile(fileId: listing.fileId, fileName: listing.fileName, credentials: credentials)
                            result.b2FilesRemoved += 1
                        }
                    } catch {
                        result.errors.append("B2 delete failed: \(image.filename) — \(error.localizedDescription)")
                    }

                    // Also delete PAR2 companion files from B2 (index + vol)
                    if !image.par2Filename.isEmpty {
                        let baseName = String(image.par2Filename.dropLast(5)) // remove ".par2"
                        let prefix = "\(image.albumPath)/\(baseName)"

                        do {
                            let listings = try await b2Service.listAllFiles(
                                bucketId: credentials.bucketId,
                                credentials: credentials,
                                prefix: prefix
                            )
                            for listing in listings where listing.fileName.hasSuffix(".par2") {
                                try await b2Service.deleteFile(fileId: listing.fileId, fileName: listing.fileName, credentials: credentials)
                            }
                        } catch {
                            // PAR2 B2 deletion is best-effort
                        }
                    }
                }

                await MainActor.run { progress.processedItems += 1 }
            }
        }

        return result
    }

    /// Walk from `directory` up to (but not including) `root`, removing each directory that is empty.
    /// Stops as soon as a non-empty directory is encountered or `root` is reached.
    private static nonisolated func removeEmptyAncestors(
        from directory: URL,
        stopAt root: URL,
        fileManager fm: FileManager
    ) {
        var current = directory.standardizedFileURL
        let stop = root.standardizedFileURL

        while current != stop, current.path.hasPrefix(stop.path) {
            guard let contents = try? fm.contentsOfDirectory(atPath: current.path),
                  contents.isEmpty else { break }
            try? fm.removeItem(at: current)
            current = current.deletingLastPathComponent().standardizedFileURL
        }
    }
}
