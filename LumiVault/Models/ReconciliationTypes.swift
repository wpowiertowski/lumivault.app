import Foundation

// MARK: - Sendable Snapshots (extracted from SwiftData models on MainActor)

struct ImageSnapshot: Sendable {
    let sha256: String
    let filename: String
    let par2Filename: String
    let b2FileId: String?
    let storageLocations: [StorageLocation]
    let albumPath: String // "year/month/day/albumName"
    /// Whether the stored bytes are AES-GCM encrypted. When true, a stored
    /// replica's bytes hash to ciphertext (not `sha256`), so the heal pass can't
    /// verify a source against `sha256` and instead trusts an intact replica.
    let isEncrypted: Bool

    /// `isEncrypted` defaults to false so existing callers/tests stay source-compatible.
    /// Explicitly `nonisolated` to match the synthesized memberwise init it replaces
    /// (a hand-written init would otherwise inherit MainActor default isolation).
    nonisolated init(
        sha256: String,
        filename: String,
        par2Filename: String,
        b2FileId: String?,
        storageLocations: [StorageLocation],
        albumPath: String,
        isEncrypted: Bool = false
    ) {
        self.sha256 = sha256
        self.filename = filename
        self.par2Filename = par2Filename
        self.b2FileId = b2FileId
        self.storageLocations = storageLocations
        self.albumPath = albumPath
        self.isEncrypted = isEncrypted
    }
}

struct VolumeSnapshot: Sendable {
    let volumeID: String
    let label: String
    let mountURL: URL
}

// MARK: - Discrepancy Model

enum DiscrepancyKind: Sendable, Hashable {
    case danglingLocation(volumeID: String)            // DB says on volume, file missing
    case orphanOnVolume(volumeID: String, path: String) // File on volume, not in DB
    case danglingB2FileId                               // DB says in B2, not found
    case orphanInB2(fileId: String, fileName: String)   // In B2, not in DB
    case missingFromVolume(volumeID: String)            // On other volumes but not this one
    case hashMismatch(volumeID: String, expected: String, actual: String) // File exists but hash differs
}

struct Discrepancy: Sendable, Identifiable {
    let id: UUID
    let sha256: String
    let filename: String
    let kind: DiscrepancyKind

    nonisolated init(sha256: String, filename: String, kind: DiscrepancyKind) {
        self.id = UUID()
        self.sha256 = sha256
        self.filename = filename
        self.kind = kind
    }
}

// MARK: - Report

struct ReconciliationReport: Sendable {
    let discrepancies: [Discrepancy]
    let scannedImages: Int
    let scannedVolumes: Int
    let scannedB2Files: Int

    nonisolated init(discrepancies: [Discrepancy], scannedImages: Int, scannedVolumes: Int, scannedB2Files: Int) {
        self.discrepancies = discrepancies
        self.scannedImages = scannedImages
        self.scannedVolumes = scannedVolumes
        self.scannedB2Files = scannedB2Files
    }
}

// MARK: - Progress

enum ReconciliationPhase: String, Sendable {
    case idle = "Idle"
    case scanningVolumes = "Scanning volumes"
    case verifyingHashes = "Verifying file integrity"
    case scanningB2 = "Scanning B2"
    case repairing = "Repairing corrupted files"
    case healing = "Restoring missing replicas"
    case resolving = "Resolving"
    case complete = "Complete"
}

@Observable
final class ReconciliationProgress: @unchecked Sendable {
    var phase: ReconciliationPhase = .idle
    var totalItems: Int = 0
    var processedItems: Int = 0
    var discrepanciesFound: Int = 0

    var fraction: Double {
        guard totalItems > 0 else { return 0 }
        return Double(processedItems) / Double(totalItems)
    }
}

// MARK: - Resolution

// MARK: - Repair

struct RepairResult: Sendable {
    let sha256: String
    let filename: String
    let volumeID: String

    enum Outcome: Sendable {
        case copiedFromVolume(String)
        case repairedViaPAR2
        case failed(String)
    }

    let outcome: Outcome
}

// MARK: - Heal (restore missing replicas across storage targets)

/// Result of healing a single missing replica: a file present in one storage
/// (another volume or B2) is fanned back out to the storage that's missing it.
struct HealResult: Sendable {
    let sha256: String
    let filename: String

    /// Where the restored bytes were sourced from.
    enum Source: Sendable {
        case volume(String) // source volumeID
        case b2
    }

    enum Outcome: Sendable {
        case restoredToVolume(volumeID: String, source: Source)
        /// Re-uploaded to B2. `newFileId` must be written back to the catalog/record.
        case restoredToB2(newFileId: String, source: Source)
        case failed(String)
    }

    let outcome: Outcome
}
