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

    enum VolumeError: Error {
        case accessDenied
    }
}
