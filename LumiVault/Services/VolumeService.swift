import Foundation
import SwiftData
import AppKit

actor VolumeService {

    func discoverMountedVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey]
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        return volumes.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let isRemovable = values.volumeIsRemovable else { return false }
            return isRemovable
        }
    }

    func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolveBookmark(_ data: Data) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard url.startAccessingSecurityScopedResource() else {
            throw VolumeError.accessDenied
        }
        return url
    }

    func mirrorAlbum(
        _ album: AlbumRecord,
        to volumeURL: URL,
        volumeID: String,
        sourceResolver: (ImageRecord) -> URL?
    ) async throws -> Int {
        var copiedCount = 0
        let basePath = volumeURL
            .appendingPathComponent(album.year, isDirectory: true)
            .appendingPathComponent(album.month, isDirectory: true)
            .appendingPathComponent(album.day, isDirectory: true)
            .appendingPathComponent(album.name, isDirectory: true)

        try FileManager.default.createDirectory(at: basePath, withIntermediateDirectories: true)

        for image in album.images {
            let alreadyOnVolume = image.storageLocations.contains { $0.volumeID == volumeID }
            guard !alreadyOnVolume else { continue }

            guard let sourceURL = sourceResolver(image) else { continue }

            let destURL = basePath.appendingPathComponent(image.filename)
            try FileManager.default.copyItem(at: sourceURL, to: destURL)

            let relativePath = "\(album.year)/\(album.month)/\(album.day)/\(album.name)/\(image.filename)"
            image.storageLocations.append(StorageLocation(volumeID: volumeID, relativePath: relativePath))
            copiedCount += 1

            // Copy PAR2 file if it exists
            if !image.par2Filename.isEmpty {
                let par2Source = sourceURL.deletingLastPathComponent().appendingPathComponent(image.par2Filename)
                let par2Dest = basePath.appendingPathComponent(image.par2Filename)
                if FileManager.default.fileExists(atPath: par2Source.path) {
                    try FileManager.default.copyItem(at: par2Source, to: par2Dest)
                }
            }
        }

        return copiedCount
    }

    // MARK: - Sync Catalog to New Volume

    struct SyncResult: Sendable {
        var copied: Int = 0
        var deduplicated: Int = 0
        var skipped: Int = 0
        var errors: [String] = []

        nonisolated init(copied: Int = 0, deduplicated: Int = 0, skipped: Int = 0, errors: [String] = []) {
            self.copied = copied
            self.deduplicated = deduplicated
            self.skipped = skipped
            self.errors = errors
        }
    }

    struct SyncImageInput: Sendable {
        let sha256: String
        let filename: String
        let par2Filename: String
        let albumPath: String // "year/month/day/albumName"
        let existingLocations: [StorageLocation]
    }

    /// Sync images to a target volume. Returns result with counts and list of
    /// StorageLocation entries to add (keyed by sha256).
    func syncToVolume(
        images: [SyncImageInput],
        targetVolumeURL: URL,
        targetVolumeID: String,
        sourceVolumes: [(volumeID: String, mountURL: URL)]
    ) async -> (result: SyncResult, newLocations: [(sha256: String, location: StorageLocation)]) {
        let hasher = HasherService()
        var result = SyncResult()
        var newLocations: [(sha256: String, location: StorageLocation)] = []

        for image in images {
            let relativePath = "\(image.albumPath)/\(image.filename)"
            let location = StorageLocation(volumeID: targetVolumeID, relativePath: relativePath)

            // Already tracked on this volume
            if image.existingLocations.contains(location) {
                result.deduplicated += 1
                continue
            }

            // Build destination path
            let destBase = targetVolumeURL.appendingPathComponent(image.albumPath, isDirectory: true)
            let destFile = destBase.appendingPathComponent(image.filename)

            // File already exists on target — verify by hash
            if FileManager.default.fileExists(atPath: destFile.path) {
                let existingHash = try? await hasher.sha256(of: destFile)
                if existingHash == image.sha256 {
                    newLocations.append((image.sha256, location))
                    result.deduplicated += 1
                } else {
                    result.errors.append("Hash mismatch: \(image.filename)")
                }
                continue
            }

            // Find a source volume that has the file
            var sourceURL: URL?
            for loc in image.existingLocations {
                if let (_, volURL) = sourceVolumes.first(where: { $0.volumeID == loc.volumeID }) {
                    let candidate = volURL.appendingPathComponent(loc.relativePath)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        sourceURL = candidate
                        break
                    }
                }
            }

            guard let source = sourceURL else {
                result.skipped += 1
                continue
            }

            do {
                try FileManager.default.createDirectory(at: destBase, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: destFile)

                // Copy PAR2 if exists
                if !image.par2Filename.isEmpty {
                    let par2Source = source.deletingLastPathComponent().appendingPathComponent(image.par2Filename)
                    let par2Dest = destBase.appendingPathComponent(image.par2Filename)
                    if FileManager.default.fileExists(atPath: par2Source.path),
                       !FileManager.default.fileExists(atPath: par2Dest.path) {
                        try FileManager.default.copyItem(at: par2Source, to: par2Dest)
                    }
                }

                newLocations.append((image.sha256, location))
                result.copied += 1
            } catch {
                result.errors.append("Copy failed: \(image.filename) — \(error.localizedDescription)")
            }
        }

        return (result, newLocations)
    }

    enum VolumeError: Error {
        case accessDenied
    }
}
