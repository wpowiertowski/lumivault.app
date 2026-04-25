import Foundation

enum ImageFormat: String, Sendable, CaseIterable {
    case original = "Original"
    case jpeg = "JPEG"
    case heic = "HEIC"
}

enum MaxDimension: Sendable, Hashable {
    case original
    case capped(Int)

    var label: String {
        switch self {
        case .original: "Original"
        case .capped(let px): "\(px)px"
        }
    }

    static let presets: [MaxDimension] = [
        .original, .capped(4096), .capped(3072), .capped(2048), .capped(1600), .capped(1024)
    ]
}

struct ImportSettings: Sendable {
    var albumName: String
    var year: String
    var month: String
    var day: String
    var generatePAR2: Bool = true
    var detectNearDuplicates: Bool = true
    var nearDuplicateThreshold: Int = Constants.Dedup.nearDuplicateThreshold
    var encryptFiles: Bool = false
    var uploadToB2: Bool = false
    var targetVolumeIDs: [String] = []
    var b2Credentials: B2Credentials?
    var imageFormat: ImageFormat = .original
    var jpegQuality: Double = 0.85
    var maxDimension: MaxDimension = .original
}

enum PipelineHealth: Sendable, Equatable {
    case normal
    case slow(SlowReason)

    enum SlowReason: Sendable, Equatable {
        case photosDownload(filename: String, attempt: Int, maxAttempts: Int, secondsUntilRetry: Int)
        case b2Retrying(attempt: Int)
        case b2Upload(filename: String)
        case photosServiceDegraded

        var message: String {
            switch self {
            case .photosDownload(let filename, let attempt, let maxAttempts, let secondsUntilRetry):
                "Waiting on iCloud download for \(filename) — attempt \(attempt + 1)/\(maxAttempts), retry in \(secondsUntilRetry)s."
            case .b2Retrying(let attempt):
                "B2 upload is slow — retrying (attempt \(attempt))."
            case .b2Upload(let filename):
                "Uploading \(filename) is taking longer than usual."
            case .photosServiceDegraded:
                "Photos services are responding slowly — import will continue."
            }
        }
    }
}

@Observable
final class PhotosImportProgress: @unchecked Sendable {
    var phase: ImportPhase = .importing
    var totalFiles: Int = 0
    var currentFile: Int = 0
    var currentFilename: String = ""
    var filesHashed: Int = 0
    var filesDeduplicated: Int = 0
    var nearDuplicatesFound: Int = 0
    var filesUploaded: Int = 0
    var filesCopied: Int = 0
    var filesConverted: Int = 0
    var filesEncrypted: Int = 0
    var filesProtected: Int = 0
    var par2FileFraction: Double = 0
    var filesCataloged: Int = 0
    var filesDropped: Int = 0
    var filesSkipped: Int = 0
    var skipReasons: [String: Int] = [:]
    var errors: [String] = []
    var nearDuplicates: [NearDuplicateMatch] = []

    var health: PipelineHealth = .normal

    /// Multi-album tracking: total files across all albums (0 = single-album mode).
    var globalTotalFiles: Int = 0
    /// Multi-album tracking: files fully processed in previously completed albums.
    var completedAlbumFiles: Int = 0

    var fraction: Double {
        guard totalFiles > 0 else {
            if globalTotalFiles > 0 {
                return Double(completedAlbumFiles) / Double(globalTotalFiles)
            }
            return 0
        }

        let albumFraction: Double
        if phase == .importing {
            albumFraction = Double(currentFile) / Double(totalFiles) * 0.1
        } else if phase == .complete {
            albumFraction = 1.0
        } else {
            albumFraction = 0.1 + Double(filesCataloged) / Double(totalFiles) * 0.9
        }

        return globalFraction(for: albumFraction)
    }

    /// Maps a per-album fraction (0–1) to a global fraction weighted by file count.
    private func globalFraction(for albumFraction: Double) -> Double {
        guard globalTotalFiles > 0 else { return albumFraction }
        let completedPortion = Double(completedAlbumFiles) / Double(globalTotalFiles)
        let albumPortion = Double(totalFiles) / Double(globalTotalFiles)
        return completedPortion + albumFraction * albumPortion
    }
}

struct NearDuplicateMatch: Identifiable, Sendable {
    let id = UUID()
    let newFilename: String
    let newSha256: String
    let existingFilename: String
    let existingSha256: String
    let hammingDistance: Int
}

enum ImportPhase: String, Sendable {
    case importing = "Importing from Photos"
    case converting = "Converting images"
    case hashing = "Hashing & finding duplicates"
    case encrypting = "Encrypting files"
    case par2 = "Generating PAR2 recovery data"
    case copying = "Copying to external volumes"
    case uploading = "Uploading to B2"
    case cataloging = "Processing images"
    case complete = "Complete"
    case failed = "Failed"

    var verb: String {
        switch self {
        case .importing: "Importing"
        case .converting: "Converting"
        case .hashing: "Hashing"
        case .encrypting: "Encrypting"
        case .par2: "PAR2"
        case .copying: "Copying"
        case .uploading: "Uploading"
        case .cataloging: "Cataloging"
        case .complete: "Done"
        case .failed: "Failed"
        }
    }
}
