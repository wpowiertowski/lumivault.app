import Foundation
import SwiftData
import AppKit
import CoreImage
import os

enum ImageFormat: String, Sendable, CaseIterable {
    case original = "Original"
    case jpeg = "JPEG"
    case heif = "HEIF"
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
    var imageFormat: ImageFormat = .original
    var jpegQuality: Double = 0.85
    var maxDimension: MaxDimension = .original
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
    var filesConverted: Int = 0
    var filesEncrypted: Int = 0
    var filesProtected: Int = 0
    var par2FileFraction: Double = 0
    var errors: [String] = []
    var nearDuplicates: [NearDuplicateMatch] = []

    /// Active phases in order, set at export start based on settings
    var activePhases: [ExportPhase] = [.exporting, .hashing, .par2, .cataloging]

    var fraction: Double {
        guard totalFiles > 0, !activePhases.isEmpty else { return 0 }

        let phaseCount = activePhases.count
        guard let phaseIndex = activePhases.firstIndex(of: phase) else {
            return phase == .complete ? 1.0 : 0.0
        }

        let phaseWeight = 1.0 / Double(phaseCount)
        let baseFraction = Double(phaseIndex) * phaseWeight

        // Per-file progress within current phase
        var phaseFraction: Double
        if phase == .par2 {
            let fileFraction = totalFiles > 0 ? Double(max(currentFile - 1, 0)) / Double(totalFiles) : 0
            let subFraction = totalFiles > 0 ? par2FileFraction / Double(totalFiles) : 0
            phaseFraction = fileFraction + subFraction
        } else {
            phaseFraction = totalFiles > 0 ? Double(currentFile) / Double(totalFiles) : 0
        }

        return baseFraction + phaseFraction * phaseWeight
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
    case converting = "Converting images"
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
        // Shared cancellation flag for non-async work (PAR2 OperationQueue)
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)

        /// Check Swift Task cancellation and propagate to shared flag
        func checkCancellation() throws {
            if Task.isCancelled {
                cancelFlag.withLock { $0 = true }
                throw CancellationError()
            }
        }

        // 1. Create staging directory
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // Determine active phases for accurate progress tracking
        let needsConversion = settings.imageFormat == .jpeg || settings.maxDimension != .original
        var phases: [ExportPhase] = [.exporting]
        if needsConversion { phases.append(.converting) }
        phases.append(.hashing)
        if settings.encryptFiles { phases.append(.encrypting) }
        if settings.generatePAR2 { phases.append(.par2) }
        if !settings.targetVolumeIDs.isEmpty { phases.append(.copying) }
        if settings.uploadToB2 { phases.append(.uploading) }
        phases.append(.cataloging)
        progress.activePhases = phases

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
        try checkCancellation()

        // 2.5. Convert images if needed (JPEG conversion / resize)
        var processedAssets = exported
        if needsConversion {
            progress.phase = .converting
            progress.currentFile = 0

            var converted: [ExportedAsset] = []
            for (index, asset) in exported.enumerated() {
                try checkCancellation()
                progress.currentFile = index + 1
                progress.currentFilename = asset.originalFilename

                let result = convertImage(
                    asset: asset,
                    format: settings.imageFormat,
                    quality: settings.jpegQuality,
                    maxDimension: settings.maxDimension,
                    staging: staging
                )
                converted.append(result)
                progress.filesConverted += 1
            }
            processedAssets = converted
        }

        try checkCancellation()
        progress.currentFile = 0
        progress.phase = .hashing

        // 3. Hash, dedup, create records
        var imageRecords: [(record: ImageRecord, fileURL: URL, isNew: Bool)] = []

        // Pre-fetch near-duplicate candidates once (instead of per-image)
        var nearDuplicateCandidates: [(sha256: String, filename: String, hash: Data)] = []
        if settings.detectNearDuplicates {
            let allDescriptor = FetchDescriptor<ImageRecord>(
                predicate: #Predicate { $0.perceptualHash != nil }
            )
            if let candidates = try? modelContext.fetch(allDescriptor) {
                nearDuplicateCandidates = candidates.compactMap { candidate in
                    guard let hash = candidate.perceptualHash else { return nil }
                    return (candidate.sha256, candidate.filename, hash)
                }
            }
        }

        for (index, asset) in processedAssets.enumerated() {
            try checkCancellation()
            progress.currentFile = index + 1
            progress.currentFilename = asset.originalFilename

            let (hash, size) = try await hasher.sha256AndSize(of: asset.fileURL)

            // Check for exact duplicates
            let descriptor = FetchDescriptor<ImageRecord>(
                predicate: #Predicate { $0.sha256 == hash }
            )
            let existing = try modelContext.fetch(descriptor)

            if let existingRecord = existing.first {
                // Reuse existing record — still include for album linking, copy, upload
                imageRecords.append((existingRecord, asset.fileURL, false))
                progress.filesDeduplicated += 1
            } else {
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

                    // Check for near-duplicates against pre-fetched candidates
                    if settings.detectNearDuplicates {
                        for candidate in nearDuplicateCandidates {
                            let distance = PerceptualHash.hammingDistance(pHash, candidate.hash)
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

                        // Add this image to candidates so subsequent imports can detect intra-batch dupes
                        nearDuplicateCandidates.append((hash, asset.originalFilename, pHash))
                    }
                }

                modelContext.insert(record)
                imageRecords.append((record, asset.fileURL, true))
            }

            progress.filesHashed += 1
        }

        try checkCancellation()

        // 4. Encrypt new files (if enabled) — before PAR2 so recovery data protects ciphertext
        var fileURLsForStorage: [String: URL] = [:] // sha256 -> file URL to use for PAR2/copy/upload
        var encryptedSizes: [String: Int64] = [:]
        for item in imageRecords {
            fileURLsForStorage[item.record.sha256] = item.fileURL
        }

        let encryptionKeyAvailable = await encryptionService.isKeyAvailable
        if settings.encryptFiles && encryptionKeyAvailable {
            progress.phase = .encrypting
            progress.currentFile = 0

            let key = await encryptionService.cachedKey!
            let keyId = await encryptionService.cachedKeyId

            let newItems = imageRecords.enumerated().filter { $0.element.isNew }
            let results = try await withThrowingTaskGroup(
                of: (index: Int, sha256: String, nonce: Data, encSize: Int64, encryptedURL: URL).self
            ) { group in
                for (index, item) in newItems {
                    let fileURL = item.fileURL
                    let sha256 = item.record.sha256
                    let filename = item.record.filename
                    let encryptedURL = staging.appendingPathComponent(filename + ".enc")

                    group.addTask {
                        try Task.checkCancellation()
                        let (nonce, encSize) = try EncryptionService.encryptFileWithKey(
                            at: fileURL, to: encryptedURL, sha256: sha256, key: key
                        )
                        return (index, sha256, nonce, encSize, encryptedURL)
                    }
                }

                var collected: [(index: Int, sha256: String, nonce: Data, encSize: Int64, encryptedURL: URL)] = []
                for try await result in group {
                    collected.append(result)
                    progress.filesEncrypted += 1
                    progress.currentFile = progress.filesEncrypted
                    progress.currentFilename = imageRecords[result.index].record.filename
                }
                return collected
            }

            for result in results {
                let item = imageRecords[result.index]
                item.record.isEncrypted = true
                item.record.encryptionNonce = result.nonce
                item.record.encryptionKeyId = keyId
                fileURLsForStorage[result.sha256] = result.encryptedURL
                encryptedSizes[result.sha256] = result.encSize
            }
        }

        // 5. Generate PAR2 recovery data for new files
        try checkCancellation()
        if settings.generatePAR2 {
            progress.phase = .par2
            progress.currentFile = 0

            let newItems = imageRecords.filter { $0.isNew }
            for (position, item) in newItems.enumerated() {
                try checkCancellation()
                progress.currentFile = position + 1
                progress.currentFilename = item.record.filename
                progress.par2FileFraction = 0

                let fileForPAR2 = fileURLsForStorage[item.record.sha256] ?? item.fileURL
                if let par2URL = try? await redundancyService.generatePAR2(
                    for: fileForPAR2,
                    outputDirectory: staging,
                    onProgress: { fraction in
                        DispatchQueue.main.async {
                            progress.par2FileFraction = fraction
                        }
                    },
                    cancelFlag: cancelFlag
                ) {
                    item.record.par2Filename = par2URL.lastPathComponent
                    progress.filesProtected += 1
                }
            }
        }

        // 6. Copy to external volumes
        try checkCancellation()
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
                    try checkCancellation()
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

                    // Copy PAR2 companion files (index + vol)
                    if !item.record.par2Filename.isEmpty {
                        let companions = RedundancyService.companionFiles(
                            forIndex: item.record.par2Filename, in: staging
                        )
                        for companion in companions {
                            let dest = destBase.appendingPathComponent(companion.lastPathComponent)
                            if !FileManager.default.fileExists(atPath: dest.path) {
                                try FileManager.default.copyItem(at: companion, to: dest)
                            }
                        }
                    }

                    progress.filesCopied += 1
                }

                volumeRecord.lastSyncedAt = .now
            }
        }

        // 7. Upload to B2
        try checkCancellation()
        if settings.uploadToB2, let credentials = settings.b2Credentials {
            progress.phase = .uploading
            progress.currentFile = 0

            for (index, item) in imageRecords.enumerated() {
                try checkCancellation()
                progress.currentFile = index + 1
                progress.currentFilename = item.record.filename

                // B2 stores decoded file names (decodes X-Bz-File-Name on upload).
                // Use raw paths for listing/existence checks; encoding only for upload headers.
                let remotePath = "\(settings.year)/\(settings.month)/\(settings.day)/\(settings.albumName)/\(item.record.filename)"

                do {
                    let alreadyExists = try await b2Service.fileExists(
                        fileName: remotePath,
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
                        // File already in B2 — look up its fileId so the record is linked
                        if item.record.b2FileId == nil {
                            let listings = try await b2Service.listAllFiles(
                                bucketId: credentials.bucketId,
                                credentials: credentials,
                                prefix: remotePath
                            )
                            if let listing = listings.first(where: { $0.fileName == remotePath }) {
                                item.record.b2FileId = listing.fileId
                            }
                        }
                        progress.filesUploaded += 1
                    }

                    // Also upload PAR2 companion files (index + vol) if not already in B2
                    if !item.record.par2Filename.isEmpty {
                        let companions = RedundancyService.companionFiles(
                            forIndex: item.record.par2Filename, in: staging
                        )
                        let remoteBase = "\(settings.year)/\(settings.month)/\(settings.day)/\(settings.albumName)"
                        for companion in companions {
                            let remoteName = "\(remoteBase)/\(companion.lastPathComponent)"
                            let exists = try await b2Service.fileExists(
                                fileName: remoteName,
                                bucketId: credentials.bucketId,
                                credentials: credentials
                            )
                            if !exists {
                                _ = try await b2Service.uploadImage(
                                    fileURL: companion,
                                    remotePath: remoteName,
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

        // 8. Create album record and update catalog
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

    // MARK: - Image Conversion

    func convertImage(
        asset: ExportedAsset,
        format: ImageFormat,
        quality: Double,
        maxDimension: MaxDimension,
        staging: URL
    ) -> ExportedAsset {
        guard let image = NSImage(contentsOf: asset.fileURL),
              let srcRep = image.representations.first else { return asset }

        // Use actual pixel dimensions, not point size (which differs on Retina)
        let pixelWidth = CGFloat(srcRep.pixelsWide)
        let pixelHeight = CGFloat(srcRep.pixelsHigh)

        var targetWidth = pixelWidth
        var targetHeight = pixelHeight
        if case .capped(let maxPx) = maxDimension {
            let maxSide = max(pixelWidth, pixelHeight)
            if maxSide > CGFloat(maxPx) {
                let scale = CGFloat(maxPx) / maxSide
                targetWidth = (pixelWidth * scale).rounded()
                targetHeight = (pixelHeight * scale).rounded()
            }
        }

        let needsResize = targetWidth != pixelWidth || targetHeight != pixelHeight
        let needsConversion = format == .jpeg || format == .heif

        guard needsResize || needsConversion else { return asset }

        // Draw into bitmap at target pixel size
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetWidth),
            pixelsHigh: Int(targetHeight),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return asset }

        // Set bitmap size to match pixel dimensions (1:1 point-to-pixel)
        bitmapRep.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        image.draw(in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
                   from: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height),
                   operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        let outputData: Data?
        let outputFilename: String
        let stem = (asset.originalFilename as NSString).deletingPathExtension

        switch format {
        case .jpeg:
            outputData = bitmapRep.representation(
                using: .jpeg,
                properties: [.compressionFactor: quality]
            )
            outputFilename = stem + ".jpg"
        case .heif:
            // Use CIImage + CIContext for HEIF encoding (NSBitmapImageRep doesn't support HEIF directly)
            if let ciImage = CIImage(bitmapImageRep: bitmapRep) {
                let context = CIContext()
                let colorSpace = ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
                let tempURL = staging.appendingPathComponent("heif-\(UUID().uuidString).heic")
                let options: [CIImageRepresentationOption: Any] = [
                    CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
                ]
                try? context.writeHEIFRepresentation(of: ciImage,
                                                     to: tempURL,
                                                     format: .RGBA8,
                                                     colorSpace: colorSpace,
                                                     options: options)
                outputData = try? Data(contentsOf: tempURL)
                try? FileManager.default.removeItem(at: tempURL)
            } else {
                outputData = nil
            }
            outputFilename = stem + ".heic"
        case .original:
            // Keep original format but resized — write as PNG
            outputData = bitmapRep.representation(using: .png, properties: [:])
            outputFilename = asset.originalFilename
        }

        guard let data = outputData else { return asset }

        let convertedDir = staging.appendingPathComponent("converted", isDirectory: true)
        try? FileManager.default.createDirectory(at: convertedDir, withIntermediateDirectories: true)
        let outputURL = convertedDir.appendingPathComponent(outputFilename)
        do {
            try data.write(to: outputURL, options: .atomic)
            return ExportedAsset(
                fileURL: outputURL,
                originalFilename: outputFilename,
                creationDate: asset.creationDate
            )
        } catch {
            return asset // fall back to original on write failure
        }
    }
}
