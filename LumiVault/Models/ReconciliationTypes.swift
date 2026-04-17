import Foundation

// MARK: - Sendable Snapshots (extracted from SwiftData models on MainActor)

struct ImageSnapshot: Sendable {
    let sha256: String
    let filename: String
    let par2Filename: String
    let b2FileId: String?
    let storageLocations: [StorageLocation]
    let albumPath: String // "year/month/day/albumName"
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
