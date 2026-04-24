import Foundation
import Photos
import SwiftData

/// What a per-album diff against the Apple Photos library looks like.
/// Not Sendable: holds `ImageRecord` (a SwiftData @Model). Lives only on
/// MainActor in practice, same constraint as `DuplicateResult`.
struct AlbumDelta {
    /// Assets present in Photos that we have not yet imported.
    let added: [PHAsset]
    /// Catalog images whose source PHAsset is no longer in the album.
    /// Only includes images with a non-nil `phAssetLocalIdentifier`.
    let removed: [ImageRecord]
    /// Catalog images that lack a `phAssetLocalIdentifier` and therefore can't
    /// participate in deletion detection. Surfaced for honest UI messaging.
    let untrackable: [ImageRecord]
    /// True if Photos no longer has this album at all (user deleted it).
    let albumMissing: Bool

    var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && !albumMissing
    }
}

/// Watches the Apple Photos library for changes to albums LumiVault has
/// imported, and exposes per-album deltas the UI can act on.
///
/// The diff itself is pure (`computeDelta(...)`) and unit-testable in
/// isolation from PhotoKit.
@Observable
@MainActor
final class PhotosLibraryMonitor: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var deltas: [PersistentIdentifier: AlbumDelta] = [:]

    private let photosService = PhotosImportService()
    private var modelContext: ModelContext?
    private var registered = false

    /// Begin observing the Photos library and run an initial diff for every
    /// catalogued album that has a `photosAlbumLocalIdentifier`.
    func start(modelContext: ModelContext) {
        self.modelContext = modelContext
        if !registered {
            PHPhotoLibrary.shared().register(self)
            registered = true
        }
        Task { await self.recheckAll() }
    }

    nonisolated func photoLibraryDidChange(_ change: PHChange) {
        Task { @MainActor [weak self] in
            await self?.recheckAll()
        }
    }

    /// Re-run diffs for every tracked album. Cheap when there are no changes.
    func recheckAll() async {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<AlbumRecord>(
            predicate: #Predicate { $0.photosAlbumLocalIdentifier != nil }
        )
        guard let albums = try? modelContext.fetch(descriptor) else { return }
        for album in albums {
            let delta = await computeDelta(for: album)
            updateDelta(album: album, delta: delta)
        }
    }

    /// Re-run the diff for a single album and return it.
    @discardableResult
    func recheck(album: AlbumRecord) async -> AlbumDelta {
        let delta = await computeDelta(for: album)
        updateDelta(album: album, delta: delta)
        return delta
    }

    /// Drop the cached delta for an album — call after a successful resync.
    func clearDelta(for album: AlbumRecord) {
        deltas.removeValue(forKey: album.persistentModelID)
    }

    // MARK: - Internal

    private func updateDelta(album: AlbumRecord, delta: AlbumDelta) {
        if delta.isEmpty {
            deltas.removeValue(forKey: album.persistentModelID)
        } else {
            deltas[album.persistentModelID] = delta
        }
    }

    private func computeDelta(for album: AlbumRecord) async -> AlbumDelta {
        guard let albumId = album.photosAlbumLocalIdentifier else {
            return AlbumDelta(added: [], removed: [], untrackable: [], albumMissing: false)
        }
        let assets = await photosService.fetchAssets(in: albumId)
        guard let assets else {
            return AlbumDelta(
                added: [],
                removed: [],
                untrackable: album.images.filter { $0.phAssetLocalIdentifier == nil },
                albumMissing: true
            )
        }
        return Self.computeDelta(photosAssets: assets, catalogImages: album.images)
    }

    /// Pure diff over PHAssets — convenience over the String-based core.
    static func computeDelta(
        photosAssets: [PHAsset],
        catalogImages: [ImageRecord]
    ) -> AlbumDelta {
        let photoIds = Set(photosAssets.map(\.localIdentifier))
        let parts = computeDeltaParts(photoIds: photoIds, catalogImages: catalogImages)
        let added = photosAssets.filter { parts.addedIds.contains($0.localIdentifier) }
        return AlbumDelta(
            added: added,
            removed: parts.removed,
            untrackable: parts.untrackable,
            albumMissing: false
        )
    }

    /// PHAsset-free core of the diff so unit tests don't need PhotoKit fixtures.
    /// Returns the IDs that need to be added (subset of `photoIds`), the
    /// catalog records that need to be removed, and the records we can't
    /// reason about because they have no PHAsset id.
    static func computeDeltaParts(
        photoIds: Set<String>,
        catalogImages: [ImageRecord]
    ) -> (addedIds: Set<String>, removed: [ImageRecord], untrackable: [ImageRecord]) {
        let catalogIds = Set(catalogImages.compactMap(\.phAssetLocalIdentifier))
        let addedIds = photoIds.subtracting(catalogIds)
        let removed = catalogImages.filter { record in
            guard let id = record.phAssetLocalIdentifier else { return false }
            return !photoIds.contains(id)
        }
        let untrackable = catalogImages.filter { $0.phAssetLocalIdentifier == nil }
        return (addedIds, removed, untrackable)
    }
}
