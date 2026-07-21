import Foundation

/// Sendable snapshot of ImageRecord fields needed across pipeline phases.
/// Created on @MainActor during the hashing phase once the record exists.
struct ImageRecordSnapshot: Sendable {
    let sha256: String
    let filename: String
    let sizeBytes: Int64
    let isNew: Bool
}

/// Item flowing through the import pipeline. Each image gets one PipelineItem
/// that accumulates results as it passes through phases.
struct PipelineItem: Sendable {
    /// Populated during the hashing phase once an ImageRecord is created/found.
    var snapshot: ImageRecordSnapshot?
    let albumName: String
    let importDate: Date
    let fileURL: URL
    let originalFilename: String
    let phAssetLocalIdentifier: String?
    var mediaType: MediaType = .image

    // Phase outputs
    var convertedURL: URL?
    var convertedFilename: String?
    var sha256: String?
    var sizeBytes: Int64 = 0
    var isDuplicate: Bool = false
    var perceptualHash: Data?
    /// Probed during the hashing phase — videos only.
    var durationSeconds: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var encryptedURL: URL?
    var encryptionNonce: Data?
    var encryptedSize: Int64?
    var par2Filename: String = ""
    var par2URL: URL?
    var storageLocations: [StorageLocation] = []
    var b2FileId: String?
    /// Fatal, stage-blocking error from an *upstream* phase (hash/encrypt/PAR2).
    /// When set, downstream copy/upload/catalog stages skip processing the item.
    var error: String?
    /// Non-blocking error from the copy stage. Recorded separately from `error`
    /// so that a failure mirroring to one storage target (external volumes) does
    /// NOT prevent the independent target (B2 upload) from running.
    var copyError: String?

    /// The filename to use for the stored file (converted name if conversion happened).
    nonisolated var activeFilename: String {
        convertedFilename ?? originalFilename
    }

    /// The file URL to use for downstream phases (encryption -> PAR2 -> copy -> upload).
    nonisolated var activeFileURL: URL {
        encryptedURL ?? convertedURL ?? fileURL
    }
}
