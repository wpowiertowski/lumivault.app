import SwiftData
import Foundation

enum ThumbnailState: Int, Codable, Sendable {
    case pending
    case generated
    case failed
}

/// `nonisolated` so services (thumbnail actor, Photos import actor, pipeline
/// stages) can construct and compare it off the main actor.
nonisolated enum MediaType: String, Codable, Sendable {
    case image
    case video
}

struct StorageLocation: Codable, Sendable, Hashable {
    var volumeID: String
    var relativePath: String
}

@Model
final class ImageRecord {
    @Attribute(.unique) var sha256: String
    var filename: String
    var sizeBytes: Int64
    var par2Filename: String
    var b2FileId: String?
    var addedAt: Date
    /// Every album this image is filed under. Many-to-many: `sha256` is unique, so
    /// one record represents the image everywhere it appears, and re-importing it
    /// into a second album adds a membership rather than a second record.
    ///
    /// This replaced a to-one `album: AlbumRecord?`, and there is no `originalName`
    /// hint or `SchemaMigrationPlan` behind it — a rename *and* a cardinality change
    /// is more than lightweight migration promises, so existing stores depend on
    /// Core Data inferring the mapping. Both ways it can go wrong are handled rather
    /// than assumed away:
    ///
    /// - The store will not open. `SwiftDataContainer.create` retries, then moves it
    ///   aside and rebuilds from catalog.json, telling the user what did not come
    ///   back (volumes need re-adding; `storageLocations` and thumbnails regenerate).
    /// - The store opens with every record intact and every membership dropped. That
    ///   is the quiet one: counts still agree, so the old staleness check saw nothing
    ///   and every album stayed empty permanently. `isHydrationStale` now treats an
    ///   image belonging to no album as stale, and hydration re-files it from the
    ///   catalog on the next launch.
    var albums: [AlbumRecord]

    /// The album whose path the stored bytes live under.
    ///
    /// Membership is a set, but the file is written once. `storageLocations` records
    /// where — so when it is populated, it is the answer, not a guess: hydration
    /// appends memberships from the merged catalog without copying anything, so a
    /// second Mac filing the same sha under an older album would otherwise flip
    /// every path derived here to a directory that has no local copy. Thumbnail
    /// regeneration then probes a path that does not exist and B2 verification
    /// reports a dangling id for a file that is present under the other prefix.
    ///
    /// Only when nothing has been copied yet (fresh import, or a store rebuilt from
    /// catalog.json, which does not restore `storageLocations`) does this fall back
    /// to a deterministic pick — earliest by date-then-name, because SwiftData does
    /// not promise a stable relationship order and `albums.first` would drift
    /// between launches.
    ///
    /// Sites that ask "is this filed anywhere?" should test `albums.isEmpty`.
    var primaryAlbum: AlbumRecord? {
        if let stored = storageLocations.first {
            let directory = (stored.relativePath as NSString).deletingLastPathComponent
            if let owning = albums.first(where: {
                "\($0.year)/\($0.month)/\($0.day)/\($0.name)" == directory
            }) {
                return owning
            }
        }
        return albums.min { lhs, rhs in
            (lhs.year, lhs.month, lhs.day, lhs.name) < (rhs.year, rhs.month, rhs.day, rhs.name)
        }
    }
    var storageLocations: [StorageLocation]
    var thumbnailState: ThumbnailState
    var perceptualHash: Data?
    var lastVerifiedAt: Date?
    var isEncrypted: Bool = false
    var encryptionKeyId: String?
    var encryptionNonce: Data?
    var phAssetLocalIdentifier: String?
    /// All Photos asset ids backed by this image. Byte-identical duplicates in
    /// Photos collapse to one stored image, so one record can be backed by
    /// several assets. `phAssetLocalIdentifier` remains as the legacy
    /// single-id field for records created before multi-asset tracking.
    var phAssetLocalIdentifiers: [String] = []
    /// Raw `MediaType`. Stored as a defaulted string so legacy stores migrate
    /// lightweight and pre-video records read as images.
    var mediaTypeRaw: String = MediaType.image.rawValue
    /// Playback duration in seconds — videos only.
    var durationSeconds: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?

    var mediaType: MediaType { MediaType(rawValue: mediaTypeRaw) ?? .image }

    /// Every Photos asset id that maps to this image, folding in the legacy
    /// single-id field.
    var allPHAssetIdentifiers: [String] {
        guard let legacy = phAssetLocalIdentifier, !phAssetLocalIdentifiers.contains(legacy) else {
            return phAssetLocalIdentifiers
        }
        return phAssetLocalIdentifiers + [legacy]
    }

    /// Drop this image from one album after that album's copy has been deleted.
    ///
    /// Deleting an image from an album is not the same as deleting the image, and
    /// the three delete paths (photo grid, near-duplicates, whole album) all used
    /// to conflate them: they removed the catalog entry and the bytes for *one*
    /// album, then deleted the whole record. An image filed under a second album
    /// vanished from it even though its catalog entry and bytes were untouched, and
    /// the next hydration brought it back with no thumbnail and no storage
    /// locations — so the integrity pass then reported it missing.
    ///
    /// Caller has already removed the catalog entry, the files under
    /// `album`'s path, and (for `entireAlbum`) the B2 prefix.
    ///
    /// - Returns: `true` when the record itself was deleted because `album` was the
    ///   last one it belonged to. `false` means the image survives elsewhere, and
    ///   the caller must *not* tear down sha-keyed shared state — the thumbnail
    ///   cache in particular is keyed by sha256, so removing it would blank the
    ///   surviving album's tile.
    @discardableResult
    func removeFromAlbum(_ album: AlbumRecord, context: ModelContext) -> Bool {
        albums.removeAll { $0.persistentModelID == album.persistentModelID }

        guard !albums.isEmpty else {
            context.delete(self)
            return true
        }

        // The bytes under this album's path are gone, so a location still pointing
        // there is a file reconciliation will look for and fail to find.
        let prefix = "\(album.year)/\(album.month)/\(album.day)/\(album.name)/"
        storageLocations.removeAll { $0.relativePath.hasPrefix(prefix) }

        // One `b2FileId` per record, and nothing records which album's object it
        // names, so after deleting this album's B2 object the id may or may not
        // still resolve. Clearing it costs at most a re-upload on the next
        // reconcile; keeping a dangling id reports a healthy photo as missing from
        // B2 and never repairs itself.
        b2FileId = nil

        return false
    }

    /// Record that `id` is a Photos asset backing this image. The array is the
    /// source of truth; the legacy scalar is only backfilled once (for records
    /// created before multi-asset tracking) and never read on its own.
    func trackPHAsset(_ id: String) {
        if !phAssetLocalIdentifiers.contains(id) {
            phAssetLocalIdentifiers.append(id)
        }
        if phAssetLocalIdentifier == nil {
            phAssetLocalIdentifier = id
        }
    }

    init(
        sha256: String,
        filename: String,
        sizeBytes: Int64,
        par2Filename: String = "",
        b2FileId: String? = nil,
        addedAt: Date = .now,
        albums: [AlbumRecord] = [],
        storageLocations: [StorageLocation] = [],
        thumbnailState: ThumbnailState = .pending,
        perceptualHash: Data? = nil,
        lastVerifiedAt: Date? = nil,
        isEncrypted: Bool = false,
        encryptionKeyId: String? = nil,
        encryptionNonce: Data? = nil,
        phAssetLocalIdentifier: String? = nil,
        mediaType: MediaType = .image,
        durationSeconds: Double? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.sha256 = sha256
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.par2Filename = par2Filename
        self.b2FileId = b2FileId
        self.addedAt = addedAt
        self.albums = albums
        self.storageLocations = storageLocations
        self.thumbnailState = thumbnailState
        self.perceptualHash = perceptualHash
        self.lastVerifiedAt = lastVerifiedAt
        self.isEncrypted = isEncrypted
        self.encryptionKeyId = encryptionKeyId
        self.encryptionNonce = encryptionNonce
        self.phAssetLocalIdentifier = phAssetLocalIdentifier
        self.phAssetLocalIdentifiers = phAssetLocalIdentifier.map { [$0] } ?? []
        self.mediaTypeRaw = mediaType.rawValue
        self.durationSeconds = durationSeconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}
