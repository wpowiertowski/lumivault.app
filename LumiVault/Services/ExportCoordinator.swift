import Foundation
import SwiftData

struct ExportSettings: Sendable {
    var albumName: String
    var year: String
    var month: String
    var day: String
    var generatePAR2: Bool = true
    var detectNearDuplicates: Bool = true
    var encryptFiles: Bool = false
    var uploadToB2: Bool = false
    var targetVolumeIDs: [String] = []
    var b2Credentials: B2Credentials?
}

@Observable
final class ExportProgress: @unchecked Sendable {
    var phase: ExportPhase = .exporting
    var totalFiles: Int = 0
    var currentFile: Int = 0
    var currentFilename: String = ""
    var filesHashed: Int = 0
    var filesDeduplicated: Int = 0
    var nearDuplicatesFound: Int = 0
    var filesUploaded: Int = 0
    var filesCopied: Int = 0
    var errors: [String] = []
    var nearDuplicates: [NearDuplicateMatch] = []

    var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(currentFile) / Double(totalFiles)
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

enum ExportPhase: String, Sendable {
    case exporting = "Exporting from Photos"
    case hashing = "Hashing & deduplicating"
    case encrypting = "Encrypting files"
    case par2 = "Generating PAR2 recovery data"
    case copying = "Copying to external volumes"
    case uploading = "Uploading to B2"
    case cataloging = "Updating catalog"
    case complete = "Complete"
    case failed = "Failed"

    var verb: String {
        switch self {
        case .exporting: "Exporting"
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

class ExportCoordinator {
    private let photosService = PhotosImportService()
    private let hasher = HasherService()
    private let thumbnailService = ThumbnailService()
    private let redundancyService = RedundancyService()
    private let b2Service = B2Service()
    private let catalogService: CatalogService
    private let encryptionService: EncryptionService

    init(catalogService: CatalogService, encryptionService: EncryptionService) {
        self.catalogService = catalogService
        self.encryptionService = encryptionService
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

                    // Check for near-duplicates against existing library
                    if settings.detectNearDuplicates {
                        let allDescriptor = FetchDescriptor<ImageRecord>(
                            predicate: #Predicate { $0.perceptualHash != nil }
                        )
                        if let candidates = try? modelContext.fetch(allDescriptor) {
                            for candidate in candidates {
                                guard let candidateHash = candidate.perceptualHash else { continue }
                                let distance = PerceptualHash.hammingDistance(pHash, candidateHash)
                                if distance < 5 {
                                    let match = NearDuplicateMatch(
                                        newFilename: asset.originalFilename,
                                        newSha256: hash,
                                        existingFilename: candidate.filename,
                                        existingSha256: candidate.sha256,
                                        hammingDistance: distance
                                    )
                                    progress.nearDuplicates.append(match)
                                    progress.nearDuplicatesFound += 1
                                    break
                                }
                            }
                        }
                    }
                }

                modelContext.insert(record)
                imageRecords.append((record, asset.fileURL))
            } else {
                progress.filesDeduplicated += 1
            }

            progress.filesHashed += 1
        }

        // 4. Encrypt files (if enabled) — before PAR2 so recovery data protects ciphertext
        var fileURLsForStorage: [String: URL] = [:] // sha256 -> file URL to use for PAR2/copy/upload
        var encryptedSizes: [String: Int64] = [:]  // sha256 -> encrypted file size
        for item in imageRecords {
            fileURLsForStorage[item.record.sha256] = item.fileURL
        }

        let encryptionKeyAvailable = await encryptionService.isKeyAvailable
        if settings.encryptFiles && encryptionKeyAvailable {
            progress.phase = .encrypting
            progress.currentFile = 0

            let keyId = await encryptionService.cachedKeyId

            for (index, item) in imageRecords.enumerated() {
                progress.currentFile = index + 1
                progress.currentFilename = item.record.filename

                let encryptedURL = staging.appendingPathComponent(item.record.filename + ".enc")
                let (nonce, encSize) = try await encryptionService.encryptFile(
                    at: item.fileURL,
                    to: encryptedURL,
                    sha256: item.record.sha256
                )

                item.record.isEncrypted = true
                item.record.encryptionNonce = nonce
                item.record.encryptionKeyId = keyId

                fileURLsForStorage[item.record.sha256] = encryptedURL
                encryptedSizes[item.record.sha256] = encSize
            }
        }

        // 5. Generate PAR2 recovery data (on ciphertext if encrypted)
        if settings.generatePAR2 {
            progress.phase = .par2
            progress.currentFile = 0

            for (index, item) in imageRecords.enumerated() {
                progress.currentFile = index + 1

                let fileForPAR2 = fileURLsForStorage[item.record.sha256] ?? item.fileURL
                if let par2URL = try? await redundancyService.generatePAR2(
                    for: fileForPAR2,
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
                    let sourceFile = fileURLsForStorage[item.record.sha256] ?? item.fileURL
                    let dest = destBase.appendingPathComponent(item.record.filename)
                    if !FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.copyItem(at: sourceFile, to: dest)
                    }

                    let relativePath = "\(settings.year)/\(settings.month)/\(settings.day)/\(settings.albumName)/\(item.record.filename)"
                    let location = StorageLocation(volumeID: volumeRecord.volumeID, relativePath: relativePath)
                    if !item.record.storageLocations.contains(location) {
                        item.record.storageLocations.append(location)
                    }

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
                let encodedPath = remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remotePath

                do {
                    let alreadyExists = try await b2Service.fileExists(
                        fileName: encodedPath,
                        bucketId: credentials.bucketId,
                        credentials: credentials
                    )

                    if !alreadyExists {
                        let uploadFile = fileURLsForStorage[item.record.sha256] ?? item.fileURL
                        let fileId = try await b2Service.uploadImage(
                            fileURL: uploadFile,
                            remotePath: remotePath,
                            sha256: item.record.sha256,
                            credentials: credentials
                        )
                        item.record.b2FileId = fileId
                        progress.filesUploaded += 1
                    } else {
                        progress.filesDeduplicated += 1
                    }

                    // Also upload PAR2 if not already in B2
                    if !item.record.par2Filename.isEmpty {
                        let par2URL = staging.appendingPathComponent(item.record.par2Filename)
                        if FileManager.default.fileExists(atPath: par2URL.path) {
                            let par2Remote = "\(settings.year)/\(settings.month)/\(settings.day)/\(settings.albumName)/\(item.record.par2Filename)"
                            let par2Encoded = par2Remote.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? par2Remote
                            let par2Exists = try await b2Service.fileExists(
                                fileName: par2Encoded,
                                bucketId: credentials.bucketId,
                                credentials: credentials
                            )
                            if !par2Exists {
                                _ = try await b2Service.uploadImage(
                                    fileURL: par2URL,
                                    remotePath: par2Remote,
                                    sha256: "",
                                    credentials: credentials
                                )
                            }
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
                b2FileId: item.record.b2FileId,
                encryptionAlgorithm: item.record.isEncrypted ? "AES-256-GCM" : nil,
                encryptionKeyId: item.record.encryptionKeyId,
                encryptionNonce: item.record.encryptionNonce?.base64EncodedString(),
                encryptedSizeBytes: encryptedSizes[item.record.sha256]
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
