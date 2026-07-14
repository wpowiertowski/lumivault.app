import Foundation
import Photos
import SwiftData

/// What a per-album diff against the Apple Photos library looks like.
/// `@unchecked Sendable` because it holds `ImageRecord` (a SwiftData @Model).
/// All access happens on MainActor in practice — the unchecked conformance
/// matches the pattern used elsewhere in the project (DuplicateResult,
/// PipelinedImportCoordinator, etc.).
struct AlbumDelta: @unchecked Sendable {
    /// Assets present in Photos that we have not yet imported.
    let added: [PHAsset]
    /// Catalog images none of whose backing PHAssets are still in the album.
    /// Only includes images with at least one tracked asset id.
    let removed: [ImageRecord]
    /// Catalog images that lack any tracked PHAsset id and therefore can't
    /// participate in deletion detection. Surfaced for honest UI messaging.
    let untrackable: [ImageRecord]
    /// True if Photos no longer has this album at all (user deleted it).
    let albumMissing: Bool

    var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && !albumMissing
    }

    /// True when `other` describes the same additions/removals — used to skip
    /// no-op `deltas` writes that would re-render observing views.
    func hasSameContent(as other: AlbumDelta) -> Bool {
        albumMissing == other.albumMissing &&
        added.map(\.localIdentifier) == other.added.map(\.localIdentifier) &&
        removed.map(\.sha256) == other.removed.map(\.sha256) &&
        untrackable.map(\.sha256) == other.untrackable.map(\.sha256)
    }
}

/// Watches the Apple Photos library for changes to albums LumiVault has
/// imported, and exposes per-album deltas the UI can act on.
///
/// The diff itself is pure (`computeDeltaCore(...)`) and unit-testable in
/// isolation from PhotoKit.
///
/// Main-actor budget: photolibraryd posts change notifications in bursts
/// (iCloud downloads during an import, background sync, analysis), and the
/// catalog records live in the main-actor ModelContext. To keep the UI
/// responsive, rechecks are trailing-edge debounced, paused entirely while an
/// import runs, and the per-album work is split so that only a single linear
/// pass over the records (one id read each) happens on the main actor — the
/// PhotoKit fetch runs on the import-service actor and the set math runs on a
/// detached task.
@Observable
@MainActor
final class PhotosLibraryMonitor: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var deltas: [PersistentIdentifier: AlbumDelta] = [:]

    private let photosService = PhotosImportService()
    private var modelContext: ModelContext?
    private var registered = false
    /// Trailing-edge debounce for photo-library change bursts.
    @ObservationIgnored private var pendingRecheck: Task<Void, Never>?
    /// While > 0 (an import or resync is running), full rechecks are deferred.
    @ObservationIgnored private var pauseCount = 0
    @ObservationIgnored private var recheckDeferredWhilePaused = false

    /// How long after the last library change notification before re-diffing.
    /// One diff per burst instead of one per notification.
    private static let debounceInterval: Duration = .seconds(2)

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
            self?.scheduleRecheck()
        }
    }

    /// Defer full rechecks — call while an import/resync runs. The pipeline
    /// mutates the same model context the diff reads, and its iCloud downloads
    /// make photolibraryd post change notifications continuously; re-diffing
    /// mid-import just steals main-actor time. Balance with `resume()`.
    func pause() {
        pauseCount += 1
    }

    func resume() {
        pauseCount = max(0, pauseCount - 1)
        if pauseCount == 0, recheckDeferredWhilePaused {
            recheckDeferredWhilePaused = false
            scheduleRecheck()
        }
    }

    /// Coalesce notification bursts into one recheck after a quiet period.
    private func scheduleRecheck() {
        pendingRecheck?.cancel()
        pendingRecheck = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            await self?.recheckAll()
        }
    }

    /// Re-run diffs for every tracked album. Deferred while paused.
    func recheckAll() async {
        guard pauseCount == 0 else {
            recheckDeferredWhilePaused = true
            return
        }
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<AlbumRecord>(
            predicate: #Predicate { $0.photosAlbumLocalIdentifier != nil }
        )
        guard let albums = try? modelContext.fetch(descriptor) else { return }
        for album in albums {
            let delta = await computeDelta(for: album)
            updateDelta(album: album, delta: delta)
            // Let the UI breathe between albums on large catalogs.
            await Task.yield()
        }
    }

    /// Re-run the diff for a single album and return it. Runs even while
    /// paused — callers use it for explicit, targeted refreshes (e.g. right
    /// after a resync completes).
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
        let key = album.persistentModelID
        if delta.isEmpty {
            if deltas[key] != nil {
                deltas.removeValue(forKey: key)
            }
        } else if !(deltas[key]?.hasSameContent(as: delta) ?? false) {
            deltas[key] = delta
        }
    }

    private func computeDelta(for album: AlbumRecord) async -> AlbumDelta {
        guard let albumId = album.photosAlbumLocalIdentifier else {
            return AlbumDelta(added: [], removed: [], untrackable: [], albumMissing: false)
        }
        // The only main-actor pass over the records: read each image's tracked
        // ids exactly once (one SwiftData array-attribute decode per record).
        let images = album.images
        let imageAssetIds = images.map(\.allPHAssetIdentifiers)

        // PhotoKit fetch runs on the import-service actor, off the main thread.
        let assets = await photosService.fetchAssets(in: albumId)
        guard let assets else {
            return AlbumDelta(
                added: [],
                removed: [],
                untrackable: zip(images, imageAssetIds).compactMap { image, ids in
                    ids.isEmpty ? image : nil
                },
                albumMissing: true
            )
        }
        let photoIds = Set(assets.map(\.localIdentifier))

        // Pure set math runs off the main actor.
        let parts = await Task.detached {
            Self.computeDeltaCore(photoIds: photoIds, imageAssetIds: imageAssetIds)
        }.value

        let added = assets.filter { parts.addedIds.contains($0.localIdentifier) }
        return AlbumDelta(
            added: added,
            removed: parts.removedIndices.map { images[$0] },
            untrackable: parts.untrackableIndices.map { images[$0] },
            albumMissing: false
        )
    }

    /// Pure diff over PHAssets — convenience over the id-based core.
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

    /// Record-based wrapper over `computeDeltaCore`: reads each record's ids
    /// exactly once, then maps the index results back to records.
    static func computeDeltaParts(
        photoIds: Set<String>,
        catalogImages: [ImageRecord]
    ) -> (addedIds: Set<String>, removed: [ImageRecord], untrackable: [ImageRecord]) {
        let imageAssetIds = catalogImages.map(\.allPHAssetIdentifiers)
        let parts = computeDeltaCore(photoIds: photoIds, imageAssetIds: imageAssetIds)
        return (
            parts.addedIds,
            parts.removedIndices.map { catalogImages[$0] },
            parts.untrackableIndices.map { catalogImages[$0] }
        )
    }

    /// PHAsset- and SwiftData-free core of the diff, safe to run off the main
    /// actor. One record can be backed by several PHAssets (byte-identical
    /// duplicates in Photos dedup to one stored image), so `imageAssetIds`
    /// carries every tracked id per image; returned indices refer to positions
    /// in `imageAssetIds`.
    nonisolated static func computeDeltaCore(
        photoIds: Set<String>,
        imageAssetIds: [[String]]
    ) -> (addedIds: Set<String>, removedIndices: [Int], untrackableIndices: [Int]) {
        var catalogIds = Set<String>()
        var removedIndices: [Int] = []
        var untrackableIndices: [Int] = []
        for (index, ids) in imageAssetIds.enumerated() {
            if ids.isEmpty {
                untrackableIndices.append(index)
                continue
            }
            var anyPresent = false
            for id in ids {
                catalogIds.insert(id)
                if photoIds.contains(id) { anyPresent = true }
            }
            if !anyPresent {
                removedIndices.append(index)
            }
        }
        return (photoIds.subtracting(catalogIds), removedIndices, untrackableIndices)
    }
}
