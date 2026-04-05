import Foundation

// MARK: - Sendable Snapshots (extracted from SwiftData models on MainActor)

struct ImageSnapshot: Sendable {
    nonisolated let sha256: String
    nonisolated let filename: String
    nonisolated let b2FileId: String?
    nonisolated let storageLocations: [StorageLocation]
    nonisolated let albumPath: String // "year/month/day/albumName"
}

struct VolumeSnapshot: Sendable {
    nonisolated let volumeID: String
    nonisolated let label: String
    nonisolated let mountURL: URL
}

// MARK: - Discrepancy Model

enum DiscrepancyKind: Sendable, Hashable {
    case danglingLocation(volumeID: String)            // DB says on volume, file missing
    case orphanOnVolume(volumeID: String, path: String) // File on volume, not in DB
    case danglingB2FileId                               // DB says in B2, not found
    case orphanInB2(fileId: String, fileName: String)   // In B2, not in DB
    case missingFromVolume(volumeID: String)            // On other volumes but not this one
}

struct Discrepancy: Sendable, Identifiable {
    nonisolated let id: UUID
    nonisolated let sha256: String
    nonisolated let filename: String
    nonisolated let kind: DiscrepancyKind

    nonisolated init(sha256: String, filename: String, kind: DiscrepancyKind) {
        self.id = UUID()
        self.sha256 = sha256
        self.filename = filename
        self.kind = kind
    }
}

// MARK: - Report

struct ReconciliationReport: Sendable {
    nonisolated let discrepancies: [Discrepancy]
    nonisolated let scannedImages: Int
    nonisolated let scannedVolumes: Int
    nonisolated let scannedB2Files: Int

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
    case scanningB2 = "Scanning B2"
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

enum ResolutionStrategy: Sendable {
    case copyFromVolume(sourceVolumeID: String, sourceURL: URL)
    case downloadFromB2(fileId: String)
    case uploadToB2
    case removeDanglingLocation
    case updateB2FileId(fileId: String)
    case ignore
}
