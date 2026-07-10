import Foundation

/// Resolves a `StorageLocation` to a filesystem URL, transparently handling the local library
/// (a fixed `~/Pictures/LumiVault` path reached via the Pictures entitlement, with no
/// security-scoped bookmark) alongside external volumes (resolved from their app-scoped bookmarks).
///
/// The library is represented by the reserved sentinel `Constants.Storage.libraryVolumeID`, so it
/// reuses the existing `volumeID → URL` machinery everywhere (copy, reconcile, heal, delete,
/// export, read) instead of needing a separate `StorageLocation` kind.
enum StorageResolver {

    /// Resolve the storage-root URL backing `location`, plus whether the caller must call
    /// `stopAccessingSecurityScopedResource()` on it when done. Returns `nil` when the location's
    /// volume is unknown or its bookmark can't be resolved (e.g. the drive is disconnected).
    ///
    /// The caller appends `location.relativePath` to the returned root and is responsible for
    /// path-escape validation (`isDescendant(of:)`) as before.
    static func resolveMount(
        for location: StorageLocation, volumes: [VolumeRecord]
    ) -> (mountURL: URL, securityScoped: Bool)? {
        if location.volumeID == Constants.Storage.libraryVolumeID {
            return (Constants.Paths.libraryURL, false)
        }
        guard let volume = volumes.first(where: { $0.volumeID == location.volumeID }),
              let url = try? BookmarkResolver.resolveAndAccess(volume.bookmarkData) else {
            return nil
        }
        return (url, true)
    }

    /// The library as a `VolumeSnapshot`, for batch services (reconcile/heal) that build a
    /// `volumeID → VolumeSnapshot` map. Safe to call from any isolation context.
    nonisolated static func librarySnapshot() -> VolumeSnapshot {
        VolumeSnapshot(
            volumeID: Constants.Storage.libraryVolumeID,
            label: Constants.Storage.libraryLabel,
            mountURL: Constants.Paths.libraryURL
        )
    }

    /// The library as a `(volumeID, mountURL)` pair, for the deletion-style `mountedVolumes` lists.
    nonisolated static func libraryMounted() -> (volumeID: String, mountURL: URL) {
        (Constants.Storage.libraryVolumeID, Constants.Paths.libraryURL)
    }

    /// Create `~/Pictures/LumiVault` if it doesn't exist yet. Best-effort.
    nonisolated static func ensureLibraryExists() {
        try? FileManager.default.createDirectory(
            at: Constants.Paths.libraryURL, withIntermediateDirectories: true
        )
    }
}
