import Foundation
import Photos

struct PhotosAlbum: Identifiable, Sendable {
    let id: String
    let title: String
    let assetCount: Int
    let startDate: Date?
    let endDate: Date?
}

struct ExportedAsset: Sendable {
    let fileURL: URL
    let originalFilename: String
    let creationDate: Date?
}

actor PhotosImportService {

    // MARK: - Authorization

    nonisolated func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - Album Enumeration

    func fetchAlbums() -> [PhotosAlbum] {
        var albums: [PhotosAlbum] = []

        // User-created albums
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil
        )
        userAlbums.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            albums.append(PhotosAlbum(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled",
                assetCount: assets.count,
                startDate: collection.startDate,
                endDate: collection.endDate
            ))
        }

        // Smart albums (Favorites, Recently Added, etc.)
        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .any, options: nil
        )
        smartAlbums.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            guard assets.count > 0 else { return }
            albums.append(PhotosAlbum(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled",
                assetCount: assets.count,
                startDate: collection.startDate,
                endDate: collection.endDate
            ))
        }

        return albums
    }

    // MARK: - Asset Export

    func exportAlbum(
        albumId: String,
        to exportDirectory: URL,
        progress: @Sendable (Int, Int) -> Void
    ) async throws -> [ExportedAsset] {
        let fetchResult = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumId], options: nil
        )
        guard let collection = fetchResult.firstObject else {
            throw PhotosImportError.albumNotFound
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(in: collection, options: fetchOptions)

        let total = assets.count
        var exported: [ExportedAsset] = []

        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        for index in 0..<total {
            let asset = assets.object(at: index)
            let result = try await exportAsset(asset, to: exportDirectory)
            exported.append(result)
            progress(index + 1, total)
        }

        return exported
    }

    // MARK: - Single Asset Export

    private func exportAsset(_ asset: PHAsset, to directory: URL) async throws -> ExportedAsset {
        let resources = PHAssetResource.assetResources(for: asset)

        // Prefer edited (fullSizePhoto) over unedited original (photo)
        // so that user edits from Photos are preserved in the export
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo })
                ?? resources.first else {
            throw PhotosImportError.noResourceFound
        }

        // Use the original resource's filename (fullSizePhoto always reports "FullSizeRender.jpeg")
        let originalResource = resources.first(where: { $0.type == .photo })
        let filename = originalResource?.originalFilename ?? resource.originalFilename
        let destURL = directory.appendingPathComponent(filename)

        // Handle filename collisions
        let finalURL = uniqueURL(for: destURL)

        try await writeResource(resource, to: finalURL)

        return ExportedAsset(
            fileURL: finalURL,
            originalFilename: filename,
            creationDate: asset.creationDate
        )
    }

    private func writeResource(_ resource: PHAssetResource, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: url,
                options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func uniqueURL(for url: URL) -> URL {
        var candidate = url
        var counter = 1
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = "\(stem)_\(counter).\(ext)"
            candidate = url.deletingLastPathComponent().appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }

    // MARK: - Errors

    enum PhotosImportError: Error {
        case albumNotFound
        case noResourceFound
        case exportFailed
    }
}
