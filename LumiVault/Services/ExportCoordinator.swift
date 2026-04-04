import Foundation
import SwiftData

struct ExportSettings: Sendable {
    var albumName: String
    var year: String
    var month: String
    var day: String
    var generatePAR2: Bool = true
    var uploadToB2: Bool = false
    var targetVolumeIDs: [String] = []
    var b2Credentials: B2Credentials?
}

@Observable
class ExportProgress {
    var phase: ExportPhase = .exporting
    var totalFiles: Int = 0
    var currentFile: Int = 0
    var currentFilename: String = ""
    var filesHashed: Int = 0
    var filesDeduplicated: Int = 0
    var filesUploaded: Int = 0
    var filesCopied: Int = 0
    var errors: [String] = []

    var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(currentFile) / Double(totalFiles)
    }
}

enum ExportPhase: String, Sendable {
    case exporting = "Exporting from Photos"
    case hashing = "Hashing & deduplicating"
    case par2 = "Generating PAR2 recovery data"
    case copying = "Copying to external volumes"
    case uploading = "Uploading to B2"
    case cataloging = "Updating catalog"
    case complete = "Complete"
    case failed = "Failed"
}

class ExportCoordinator {
    private let photosService = PhotosImportService()
    private let hasher = HasherService()
    private let thumbnailService = ThumbnailService()
    private let redundancyService = RedundancyService()
    private let b2Service = B2Service()
    private let catalogService: CatalogService

    init(catalogService: CatalogService) {
        self.catalogService = catalogService
    }

    func export(
        photosAlbumId: String,
        settings: ExportSettings,
        modelContext: ModelContext,
        progress: ExportProgress
    ) async throws {
        // 1. Create staging directory
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // 2. Export from Photos library
        progress.phase = .exporting
        let exported = try await photosService.exportAlbum(
            albumId: photosAlbumId,
            to: staging
        ) { current, total in
            Task { @MainActor in
                progress.currentFile = current
                progress.totalFiles = total
            }
        }

        progress.totalFiles = exported.count
        progress.currentFile = 0
        progress.phase = .hashing

        // 3. Hash, dedup, create records
        var imageRecords: [(record: ImageRecord, fileURL: URL)] = []

        for (index, asset) in exported.enumerated() {
            progress.currentFile = index + 1
            progress.currentFilename = asset.originalFilename

            let (hash, size) = try await hasher.sha256AndSize(of: asset.fileURL)

            // Check for duplicates
            let descriptor = FetchDescriptor<ImageRecord>(
                predicate: #Predicate { $0.sha256 == hash }
            )
            let existing = try modelContext.fetch(descriptor)

            if existing.isEmpty {
                let record = ImageRecord(
                    sha256: hash,
                    filename: asset.originalFilename,
                    sizeBytes: size
                )

                // Generate thumbnail
                try? await thumbnailService.generateThumbnail(for: asset.fileURL, sha256: hash)
                record.thumbnailState = .generated

                // Compute perceptual hash
                if let pHash = try? PerceptualHash.compute(for: asset.fileURL) {
                    record.perceptualHash = pHash
                }

                modelContext.insert(record)
                imageRecords.append((record, asset.fileURL))
            } else {
                progress.filesDeduplicated += 1
            }

            progress.filesHashed += 1
        }

        // 4. Generate PAR2 recovery data
        if settings.generatePAR2 {
            progress.phase = .par2
            progress.currentFile = 0

            for (index, item) in imageRecords.enumerated() {
                progress.currentFile = index + 1

                if let par2URL = try? await redundancyService.generatePAR2(
                    for: item.fileURL,
                    outputDirectory: staging
                ) {
                    item.record.par2Filename = par2URL.lastPathComponent
                }
            }
        }

        // 5. Copy to external volumes
        if !settings.targetVolumeIDs.isEmpty {
            progress.phase = .copying
            progress.currentFile = 0

            let volumeDescriptor = FetchDescriptor<VolumeRecord>()
            let allVolumes = try modelContext.fetch(volumeDescriptor)

            for volumeRecord in allVolumes where settings.targetVolumeIDs.contains(volumeRecord.volumeID) {
                guard let volumeURL = try? BookmarkResolver.resolveAndAccess(volumeRecord.bookmarkData) else {
                    progress.errors.append("Cannot access volume: \(volumeRecord.label)")
                    continue
                }
                defer { volumeURL.stopAccessingSecurityScopedResource() }

                let destBase = volumeURL
                    .appendingPathComponent(settings.year, isDirectory: true)
                    .appendingPathComponent(settings.month, isDirectory: true)
                    .appendingPathComponent(settings.day, isDirectory: true)
                    .appendingPathComponent(settings.albumName, isDirectory: true)

                try FileManager.default.createDirectory(at: destBase, withIntermediateDirectories: true)

                for item in imageRecords {
                    let dest = destBase.appendingPathComponent(item.record.filename)
                    if !FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.copyItem(at: item.fileURL, to: dest)
                    }

                    let relativePath = "\(settings.year)/\(settings.month)/\(settings.day)/\(settings.albumName)/\(item.record.filename)"
                    item.record.storageLocations.append(
                        StorageLocation(volumeID: volumeRecord.volumeID, relativePath: relativePath)
                    )

                    // Copy PAR2 if exists
                    if !item.record.par2Filename.isEmpty {
                        let par2Source = staging.appendingPathComponent(item.record.par2Filename)
                        let par2Dest = destBase.appendingPathComponent(item.record.par2Filename)
                        if FileManager.default.fileExists(atPath: par2Source.path),
                           !FileManager.default.fileExists(atPath: par2Dest.path) {
                            try FileManager.default.copyItem(at: par2Source, to: par2Dest)
                        }
                    }

                    progress.filesCopied += 1
                }

                volumeRecord.lastSyncedAt = .now
            }
        }

        // 6. Upload to B2
        if settings.uploadToB2, let credentials = settings.b2Credentials {
            progress.phase = .uploading
            progress.currentFile = 0

            for (index, item) in imageRecords.enumerated() {
                progress.currentFile = index + 1
                progress.currentFilename = item.record.filename

                let remotePath = "\(settings.year)/\(settings.month)/\(settings.day)/\(settings.albumName)/\(item.record.filename)"

                do {
                    let fileId = try await b2Service.uploadImage(
                        fileURL: item.fileURL,
                        remotePath: remotePath,
                        sha256: item.record.sha256,
                        credentials: credentials
                    )
                    item.record.b2FileId = fileId
                    progress.filesUploaded += 1

                    // Also upload PAR2
                    if !item.record.par2Filename.isEmpty {
                        let par2URL = staging.appendingPathComponent(item.record.par2Filename)
                        if FileManager.default.fileExists(atPath: par2URL.path) {
                            let par2Remote = "\(settings.year)/\(settings.month)/\(settings.day)/\(settings.albumName)/\(item.record.par2Filename)"
                            _ = try await b2Service.uploadImage(
                                fileURL: par2URL,
                                remotePath: par2Remote,
                                sha256: "",
                                credentials: credentials
                            )
                        }
                    }
                } catch {
                    progress.errors.append("B2 upload failed: \(item.record.filename) — \(error.localizedDescription)")
                }
            }
        }

        // 7. Create album record and update catalog
        progress.phase = .cataloging

        let albumRecord = AlbumRecord(
            name: settings.albumName,
            year: settings.year,
            month: settings.month,
            day: settings.day
        )
        modelContext.insert(albumRecord)

        for item in imageRecords {
            item.record.album = albumRecord
            albumRecord.images.append(item.record)

            let catalogImage = CatalogImage(
                filename: item.record.filename,
                sha256: item.record.sha256,
                sizeBytes: item.record.sizeBytes,
                par2Filename: item.record.par2Filename,
                b2FileId: item.record.b2FileId
            )
            await catalogService.addImage(
                catalogImage,
                toAlbum: settings.albumName,
                year: settings.year,
                month: settings.month,
                day: settings.day
            )
        }

        try modelContext.save()

        // Save catalog to disk
        let catalogPath = NSString(string: UserDefaults.standard.string(forKey: "catalogPath") ?? Constants.Paths.defaultCatalog).expandingTildeInPath
        try await catalogService.save(to: URL(fileURLWithPath: catalogPath))

        progress.phase = .complete
    }
}
