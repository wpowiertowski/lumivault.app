import SwiftData
import Foundation

enum ThumbnailState: Int, Codable, Sendable {
    case pending
    case generated
    case failed
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
    var album: AlbumRecord?
    var storageLocations: [StorageLocation]
    var thumbnailState: ThumbnailState
    var perceptualHash: Data?
    var lastVerifiedAt: Date?
    var isEncrypted: Bool = false
    var encryptionKeyId: String?
    var encryptionNonce: Data?
    var phAssetLocalIdentifier: String?

    init(
        sha256: String,
        filename: String,
        sizeBytes: Int64,
        par2Filename: String = "",
        b2FileId: String? = nil,
        addedAt: Date = .now,
        album: AlbumRecord? = nil,
        storageLocations: [StorageLocation] = [],
        thumbnailState: ThumbnailState = .pending,
        perceptualHash: Data? = nil,
        lastVerifiedAt: Date? = nil,
        isEncrypted: Bool = false,
        encryptionKeyId: String? = nil,
        encryptionNonce: Data? = nil,
        phAssetLocalIdentifier: String? = nil
    ) {
        self.sha256 = sha256
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.par2Filename = par2Filename
        self.b2FileId = b2FileId
        self.addedAt = addedAt
        self.album = album
        self.storageLocations = storageLocations
        self.thumbnailState = thumbnailState
        self.perceptualHash = perceptualHash
        self.lastVerifiedAt = lastVerifiedAt
        self.isEncrypted = isEncrypted
        self.encryptionKeyId = encryptionKeyId
        self.encryptionNonce = encryptionNonce
        self.phAssetLocalIdentifier = phAssetLocalIdentifier
    }
}
