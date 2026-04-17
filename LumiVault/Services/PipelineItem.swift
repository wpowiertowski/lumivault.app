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

    // Phase outputs
    var convertedURL: URL?
    var convertedFilename: String?
    var sha256: String?
    var sizeBytes: Int64 = 0
    var isDuplicate: Bool = false
    var perceptualHash: Data?
    var encryptedURL: URL?
    var encryptionNonce: Data?
    var encryptedSize: Int64?
    var par2Filename: String = ""
    var par2URL: URL?
    var storageLocations: [StorageLocation] = []
    var b2FileId: String?
    var error: String?

    /// The filename to use for the stored file (converted name if conversion happened).
    var activeFilename: String {
        convertedFilename ?? originalFilename
    }

    /// The file URL to use for downstream phases (encryption -> PAR2 -> copy -> upload).
    var activeFileURL: URL {
        encryptedURL ?? convertedURL ?? fileURL
    }
}
