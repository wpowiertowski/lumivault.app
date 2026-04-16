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
    ///
    /// - `entireAlbum = true` (default): removes the album directory (`year/month/day/albumName`)
    ///   directly, then prunes empty ancestors. B2: lists all objects under the album prefix.
    /// - `entireAlbum = false`: removes only the specific files listed in `images` by
    ///   `albumPath/filename` (and their PAR2 companions). B2: deletes by specific file name.
    func deleteImageFiles(
        images: [ImageDeletionInput],
        mountedVolumes: [(volumeID: String, mountURL: URL)],
        b2Credentials: B2Credentials?,
        progress: DeletionProgress,
        entireAlbum: Bool = true
    ) async -> DeletionResult {
        var result = DeletionResult()
        let fm = FileManager.default

        // All images in a deletion batch share the same albumPath.
        guard let albumPath = images.first?.albumPath else { return result }

        // Phase 1: Remove from each mounted volume
        await MainActor.run {
            progress.phase = .removingFromVolumes
            progress.totalItems = mountedVolumes.count + (b2Credentials != nil ? 1 : 0)
        }

        for (_, mountURL) in mountedVolumes {
            let albumDir = mountURL.appendingPathComponent(albumPath, isDirectory: true)

            if entireAlbum {
                // Remove the entire album directory
                do {
                    if fm.fileExists(atPath: albumDir.path) {
                        let contents = try fm.contentsOfDirectory(atPath: albumDir.path)
                        try fm.removeItem(at: albumDir)
                        result.volumeFilesRemoved += contents.count
                    }
                    Self.removeEmptyAncestors(
                        from: albumDir.deletingLastPathComponent(),
                        stopAt: mountURL,
                        fileManager: fm
                    )
                } catch {
                    result.errors.append("Volume remove failed: \(albumPath) — \(error.localizedDescription)")
                }
            } else {
                // Remove only specific files
                for image in images {
                    let filePath = albumDir.appendingPathComponent(image.filename)
                    if fm.fileExists(atPath: filePath.path) {
                        do {
                            try fm.removeItem(at: filePath)
                            result.volumeFilesRemoved += 1
                        } catch {
                            result.errors.append("Volume remove failed: \(image.filename) — \(error.localizedDescription)")
                        }
                    }
                    // Also remove PAR2 companion if present
                    if !image.par2Filename.isEmpty {
                        let par2Path = albumDir.appendingPathComponent(image.par2Filename)
                        if fm.fileExists(atPath: par2Path.path) {
                            try? fm.removeItem(at: par2Path)
                        }
                    }
                }
                // Prune empty directories after individual file removal
                Self.removeEmptyAncestors(
                    from: albumDir,
                    stopAt: mountURL,
                    fileManager: fm
                )
            }

            await MainActor.run { progress.processedItems += 1 }
        }

        // Phase 2: Remove from B2
        if let credentials = b2Credentials {
            await MainActor.run { progress.phase = .removingFromB2 }

            if entireAlbum {
                // List and delete all objects under the album prefix
                do {
                    let listings = try await b2Service.listAllFiles(
                        bucketId: credentials.bucketId,
                        credentials: credentials,
                        prefix: albumPath + "/"
                    )
                    for listing in listings {
                        try await b2Service.deleteFile(
                            fileId: listing.fileId,
                            fileName: listing.fileName,
                            credentials: credentials
                        )
                        result.b2FilesRemoved += 1
                    }
                } catch {
                    result.errors.append("B2 delete failed: \(albumPath) — \(error.localizedDescription)")
                }
            } else {
                // Delete specific files by listing with their exact prefix
                for image in images {
                    let filePrefix = albumPath + "/" + image.filename
                    do {
                        let listings = try await b2Service.listAllFiles(
                            bucketId: credentials.bucketId,
                            credentials: credentials,
                            prefix: filePrefix
                        )
                        for listing in listings {
                            try await b2Service.deleteFile(
                                fileId: listing.fileId,
                                fileName: listing.fileName,
                                credentials: credentials
                            )
                            result.b2FilesRemoved += 1
                        }
                    } catch {
                        result.errors.append("B2 delete failed: \(image.filename) — \(error.localizedDescription)")
                    }
                    // Also delete PAR2 companion from B2
                    if !image.par2Filename.isEmpty {
                        let par2Prefix = albumPath + "/" + image.par2Filename
                        if let listings = try? await b2Service.listAllFiles(
                            bucketId: credentials.bucketId,
                            credentials: credentials,
                            prefix: par2Prefix
                        ) {
                            for listing in listings {
                                try? await b2Service.deleteFile(
                                    fileId: listing.fileId,
                                    fileName: listing.fileName,
                                    credentials: credentials
                                )
                                result.b2FilesRemoved += 1
                            }
                        }
                    }
                }
            }

            await MainActor.run { progress.processedItems += 1 }
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
