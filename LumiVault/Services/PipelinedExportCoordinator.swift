import Foundation
import SwiftData
import AppKit
import CoreImage
import os

/// Wrapper to pass MainActor-isolated values into @MainActor Task closures
/// where the compiler can't prove isolation safety.
private struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
}

/// Export coordinator that pipelines images through phases so that
/// already-converted images can hash while later images still convert, etc.
///
/// Pipeline topology (phases skipped when disabled):
///   Export -> Conversion -> Hashing/Dedup -> Encryption -> PAR2 -> Copy -> Upload -> Catalog
class PipelinedExportCoordinator: @unchecked Sendable {
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
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)

        // Staging directory
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // Determine active phases
        let needsConversion = settings.imageFormat != .original || settings.maxDimension != .original
        let encryptionKeyAvailable = await encryptionService.isKeyAvailable
        let needsEncryption = settings.encryptFiles && encryptionKeyAvailable
        let needsPAR2 = settings.generatePAR2
        let needsCopy = !settings.targetVolumeIDs.isEmpty
        let needsUpload = settings.uploadToB2 && settings.b2Credentials != nil

        var phases: [ExportPhase] = [.exporting]
        if needsConversion { phases.append(.converting) }
        phases.append(.hashing)
        if needsEncryption { phases.append(.encrypting) }
        if needsPAR2 { phases.append(.par2) }
        if needsCopy { phases.append(.copying) }
        if needsUpload { phases.append(.uploading) }
        phases.append(.cataloging)
        await MainActor.run {
            progress.activePhases = phases
            progress.isPipelined = true
            progress.phase = .exporting
        }

        // 1. Export from Photos
        let exported = try await photosService.exportAlbum(
            albumId: photosAlbumId,
            to: staging
        ) { current, total in
            Task { @MainActor in
                progress.currentFile = current
                progress.totalFiles = total
            }
        }
        await MainActor.run { progress.totalFiles = exported.count }

        if Task.isCancelled {
            cancelFlag.withLock { $0 = true }
            throw CancellationError()
        }

        // Create channels
        let conversionCh = AsyncChannel<PipelineItem>(bufferSize: 4)
        let hashingCh = AsyncChannel<PipelineItem>(bufferSize: needsConversion ? 4 : 8)
        let encryptionCh = AsyncChannel<PipelineItem>(bufferSize: 4)
        let par2Ch = AsyncChannel<PipelineItem>(bufferSize: 2)
        let copyCh = AsyncChannel<PipelineItem>(bufferSize: 4)
        let uploadCh = AsyncChannel<PipelineItem>(bufferSize: 4)
        let catalogCh = AsyncChannel<PipelineItem>(bufferSize: 4)

        // Wire channels: each phase sends to the next active phase
        let postConversion = hashingCh
        let postHashing: AsyncChannel<PipelineItem> = needsEncryption ? encryptionCh : (needsPAR2 ? par2Ch : (needsCopy ? copyCh : (needsUpload ? uploadCh : catalogCh)))
        let postEncryption: AsyncChannel<PipelineItem> = needsPAR2 ? par2Ch : (needsCopy ? copyCh : (needsUpload ? uploadCh : catalogCh))
        let postPAR2: AsyncChannel<PipelineItem> = needsCopy ? copyCh : (needsUpload ? uploadCh : catalogCh)
        let postCopy: AsyncChannel<PipelineItem> = needsUpload ? uploadCh : catalogCh
        let postUpload = catalogCh

        // Pre-fetch near-duplicate candidates
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

        // Encryption key (captured once)
        let encKey = needsEncryption ? await encryptionService.cachedKey : nil
        let encKeyId = needsEncryption ? await encryptionService.cachedKeyId : nil

        // Resolve volumes once
        var resolvedVolumes: [(record: VolumeRecord, url: URL)] = []
        if needsCopy {
            let volumeDescriptor = FetchDescriptor<VolumeRecord>()
            let allVolumes = try modelContext.fetch(volumeDescriptor)
            for vol in allVolumes where settings.targetVolumeIDs.contains(vol.volumeID) {
                if let url = try? BookmarkResolver.resolveAndAccess(vol.bookmarkData) {
                    resolvedVolumes.append((vol, url))
                } else {
                    progress.errors.append("Cannot access volume: \(vol.label)")
                }
            }
        }

        // Wrap non-Sendable values for Task capture. These tasks all run on
        // @MainActor so this is safe — the compiler just can't prove it.
        let ctx = UnsafeSendable(value: modelContext)
        let vols = UnsafeSendable(value: resolvedVolumes)

        // Collect all channels so we can cancel them all on teardown
        let allChannels: [any CancellableChannel] = [
            conversionCh, hashingCh, encryptionCh, par2Ch, copyCh, uploadCh, catalogCh
        ]

        // MARK: - Feed
        let firstChannel = needsConversion ? conversionCh : hashingCh
        let feedTask = Task { @MainActor [exported, settings] in
            for asset in exported {
                guard !Task.isCancelled else { break }
                let item = PipelineItem(
                    albumName: settings.albumName,
                    exportDate: .now,
                    fileURL: asset.fileURL,
                    originalFilename: asset.originalFilename
                )
                await firstChannel.send(item)
            }
            firstChannel.finish()
        }

        // MARK: - Conversion
        var conversionTask: Task<Void, Never>?
        if needsConversion {
            conversionTask = Task { @MainActor [settings] in
                progress.phase = .converting

                for await item in conversionCh.stream {
                    await conversionCh.consumed()
                    guard !Task.isCancelled else { continue }

                    var mutableItem = item
                    let converted = self.convertImage(
                        asset: ExportedAsset(
                            fileURL: item.fileURL,
                            originalFilename: item.originalFilename,
                            creationDate: nil
                        ),
                        format: settings.imageFormat,
                        quality: settings.jpegQuality,
                        maxDimension: settings.maxDimension,
                        staging: staging
                    )
                    if converted.fileURL != item.fileURL {
                        mutableItem.convertedURL = converted.fileURL
                    }
                    progress.filesConverted += 1
                    progress.currentFile = progress.filesConverted
                    progress.currentFilename = item.originalFilename

                    await postConversion.send(mutableItem)
                }
                postConversion.finish()
            }
        }

        // MARK: - Hashing & Dedup
        let candidatesLock = OSAllocatedUnfairLock(initialState: nearDuplicateCandidates)

        let hashTask = Task { @MainActor [ctx, settings] in
            let modelContext = ctx.value
            progress.phase = .hashing
            progress.currentFile = 0

            for await item in hashingCh.stream {
                await hashingCh.consumed()
                guard !Task.isCancelled else { continue }

                var mutableItem = item
                let fileToHash = item.convertedURL ?? item.fileURL
                do {
                    let (hash, size) = try await self.hasher.sha256AndSize(of: fileToHash)
                    mutableItem.sha256 = hash
                    mutableItem.sizeBytes = size

                    let descriptor = FetchDescriptor<ImageRecord>(
                        predicate: #Predicate { $0.sha256 == hash }
                    )
                    let existing = try modelContext.fetch(descriptor)

                    if let existingRecord = existing.first {
                        mutableItem.isDuplicate = true
                        mutableItem.snapshot = ImageRecordSnapshot(
                            persistentModelID: existingRecord.persistentModelID,
                            sha256: hash,
                            filename: existingRecord.filename,
                            sizeBytes: existingRecord.sizeBytes,
                            isNew: false
                        )
                        progress.filesDeduplicated += 1
                    } else {
                        let record = ImageRecord(
                            sha256: hash,
                            filename: item.originalFilename,
                            sizeBytes: size
                        )
                        try? await self.thumbnailService.generateThumbnail(for: fileToHash, sha256: hash)
                        record.thumbnailState = .generated

                        if let pHash = try? PerceptualHash.compute(for: fileToHash) {
                            record.perceptualHash = pHash
                            mutableItem.perceptualHash = pHash

                            if settings.detectNearDuplicates {
                                let originalFilename = item.originalFilename
                                let candidates = candidatesLock.withLock { $0 }
                                for candidate in candidates {
                                    let distance = PerceptualHash.hammingDistance(pHash, candidate.hash)
                                    if distance < 5 {
                                        let match = NearDuplicateMatch(
                                            newFilename: originalFilename,
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
                                candidatesLock.withLock {
                                    $0.append((hash, originalFilename, pHash))
                                }
                            }
                        }

                        modelContext.insert(record)
                        mutableItem.snapshot = ImageRecordSnapshot(
                            persistentModelID: record.persistentModelID,
                            sha256: hash,
                            filename: item.originalFilename,
                            sizeBytes: size,
                            isNew: true
                        )
                    }
                } catch {
                    mutableItem.error = "Hash failed: \(item.originalFilename) — \(error.localizedDescription)"
                    progress.errors.append(mutableItem.error!)
                }

                progress.filesHashed += 1
                progress.currentFile = progress.filesHashed
                progress.currentFilename = item.originalFilename

                await postHashing.send(mutableItem)
            }
            postHashing.finish()
        }

        // MARK: - Encryption
        var encryptionTask: Task<Void, Never>?
        if needsEncryption, let key = encKey {
            encryptionTask = Task { @MainActor [ctx] in
                let modelContext = ctx.value
                progress.phase = .encrypting
                progress.currentFile = 0

                for await item in encryptionCh.stream {
                    await encryptionCh.consumed()
                    guard !Task.isCancelled else { continue }

                    var mutableItem = item
                    guard let snap = item.snapshot, item.error == nil, snap.isNew else {
                        await postEncryption.send(mutableItem)
                        continue
                    }

                    let encryptedURL = staging.appendingPathComponent(snap.filename + ".enc")
                    do {
                        let (nonce, encSize) = try EncryptionService.encryptFileWithKey(
                            at: item.activeFileURL, to: encryptedURL, sha256: snap.sha256, key: key
                        )
                        mutableItem.encryptedURL = encryptedURL
                        mutableItem.encryptionNonce = nonce
                        mutableItem.encryptedSize = encSize

                        if let record = modelContext.model(for: snap.persistentModelID) as? ImageRecord {
                            record.isEncrypted = true
                            record.encryptionNonce = nonce
                            record.encryptionKeyId = encKeyId
                        }

                        progress.filesEncrypted += 1
                        progress.currentFile = progress.filesEncrypted
                        progress.currentFilename = snap.filename
                    } catch {
                        mutableItem.error = "Encrypt failed: \(snap.filename) — \(error.localizedDescription)"
                        progress.errors.append(mutableItem.error!)
                    }

                    await postEncryption.send(mutableItem)
                }
                postEncryption.finish()
            }
        }

        // MARK: - PAR2
        var par2Task: Task<Void, Never>?
        if needsPAR2 {
            par2Task = Task { @MainActor [ctx] in
                let modelContext = ctx.value
                progress.phase = .par2
                progress.currentFile = 0

                for await item in par2Ch.stream {
                    await par2Ch.consumed()
                    guard !Task.isCancelled else { continue }

                    var mutableItem = item
                    guard let snap = item.snapshot, item.error == nil, snap.isNew else {
                        await postPAR2.send(mutableItem)
                        continue
                    }

                    progress.currentFilename = snap.filename
                    progress.par2FileFraction = 0

                    do {
                        let par2URL = try self.redundancyService.generatePAR2(
                            for: item.activeFileURL,
                            outputDirectory: staging,
                            onProgress: { fraction in
                                DispatchQueue.main.async {
                                    progress.par2FileFraction = fraction
                                }
                            },
                            cancelFlag: cancelFlag
                        )
                        mutableItem.par2Filename = par2URL.lastPathComponent
                        mutableItem.par2URL = par2URL

                        if let record = modelContext.model(for: snap.persistentModelID) as? ImageRecord {
                            record.par2Filename = par2URL.lastPathComponent
                        }

                        progress.filesProtected += 1
                    } catch {
                        mutableItem.error = "PAR2 failed: \(snap.filename) — \(error.localizedDescription)"
                        progress.errors.append(mutableItem.error!)
                    }

                    progress.currentFile += 1
                    await postPAR2.send(mutableItem)
                }
                postPAR2.finish()
            }
        }

        // MARK: - Copy to Volumes
        var copyTask: Task<Void, Never>?
        if needsCopy {
            copyTask = Task { @MainActor [ctx, vols, settings] in
                let modelContext = ctx.value
                let resolvedVolumes = vols.value
                progress.phase = .copying
                progress.currentFile = 0

                for await item in copyCh.stream {
                    await copyCh.consumed()
                    guard !Task.isCancelled else { continue }

                    var mutableItem = item
                    guard let snap = item.snapshot, item.error == nil else {
                        await postCopy.send(mutableItem)
                        continue
                    }

                    let sourceFile = item.activeFileURL
                    for (volRecord, volURL) in resolvedVolumes {
                        let destBase = volURL
                            .appendingPathComponent(settings.year, isDirectory: true)
                            .appendingPathComponent(settings.month, isDirectory: true)
                            .appendingPathComponent(settings.day, isDirectory: true)
                            .appendingPathComponent(settings.albumName, isDirectory: true)

                        do {
                            try FileManager.default.createDirectory(at: destBase, withIntermediateDirectories: true)

                            let dest = destBase.appendingPathComponent(snap.filename)
                            if !FileManager.default.fileExists(atPath: dest.path) {
                                try FileManager.default.copyItem(at: sourceFile, to: dest)
                            }

                            let relativePath = "\(settings.year)/\(settings.month)/\(settings.day)/\(settings.albumName)/\(snap.filename)"
                            let location = StorageLocation(volumeID: volRecord.volumeID, relativePath: relativePath)
                            if !mutableItem.storageLocations.contains(location) {
                                mutableItem.storageLocations.append(location)
                            }

                            if let record = modelContext.model(for: snap.persistentModelID) as? ImageRecord {
                                if !record.storageLocations.contains(location) {
                                    record.storageLocations.append(location)
                                }
                            }

                            // Copy PAR2 companion files (index + vol)
                            if !item.par2Filename.isEmpty {
                                let companions = RedundancyService.companionFiles(
                                    forIndex: item.par2Filename, in: staging
                                )
                                for companion in companions {
                                    let dest = destBase.appendingPathComponent(companion.lastPathComponent)
                                    if !FileManager.default.fileExists(atPath: dest.path) {
                                        try FileManager.default.copyItem(at: companion, to: dest)
                                    }
                                }
                            }
                        } catch {
                            mutableItem.error = "Copy failed: \(snap.filename) to \(volRecord.label) — \(error.localizedDescription)"
                            progress.errors.append(mutableItem.error!)
                        }
                    }

                    progress.filesCopied += 1
                    await postCopy.send(mutableItem)
                }

                for (volRecord, volURL) in resolvedVolumes {
                    volRecord.lastSyncedAt = .now
                    volURL.stopAccessingSecurityScopedResource()
                }
                postCopy.finish()
            }
        }

        // MARK: - B2 Upload
        var uploadTask: Task<Void, Never>?
        if needsUpload, let credentials = settings.b2Credentials {
            uploadTask = Task { @MainActor [ctx] in
                let modelContext = ctx.value
                progress.phase = .uploading
                progress.currentFile = 0

                for await item in uploadCh.stream {
                    await uploadCh.consumed()
                    guard !Task.isCancelled else { continue }

                    var mutableItem = item
                    guard let snap = item.snapshot, item.error == nil else {
                        await postUpload.send(mutableItem)
                        continue
                    }

                    let remotePath = "\(settings.year)/\(settings.month)/\(settings.day)/\(settings.albumName)/\(snap.filename)"

                    do {
                        let alreadyExists = try await self.b2Service.fileExists(
                            fileName: remotePath,
                            bucketId: credentials.bucketId,
                            credentials: credentials
                        )

                        if !alreadyExists {
                            let fileId = try await self.b2Service.uploadImage(
                                fileURL: item.activeFileURL,
                                remotePath: remotePath,
                                sha256: snap.sha256,
                                credentials: credentials
                            )
                            mutableItem.b2FileId = fileId
                            if let record = modelContext.model(for: snap.persistentModelID) as? ImageRecord {
                                record.b2FileId = fileId
                            }
                        } else {
                            if let record = modelContext.model(for: snap.persistentModelID) as? ImageRecord,
                               record.b2FileId == nil {
                                let listings = try await self.b2Service.listAllFiles(
                                    bucketId: credentials.bucketId,
                                    credentials: credentials,
                                    prefix: remotePath
                                )
                                if let listing = listings.first(where: { $0.fileName == remotePath }) {
                                    record.b2FileId = listing.fileId
                                }
                            }
                        }

                        // Upload PAR2 companion files (index + vol)
                        if !item.par2Filename.isEmpty {
                            let companions = RedundancyService.companionFiles(
                                forIndex: item.par2Filename, in: staging
                            )
                            let remoteBase = "\(settings.year)/\(settings.month)/\(settings.day)/\(settings.albumName)"
                            for companion in companions {
                                let remoteName = "\(remoteBase)/\(companion.lastPathComponent)"
                                let exists = try await self.b2Service.fileExists(
                                    fileName: remoteName,
                                    bucketId: credentials.bucketId,
                                    credentials: credentials
                                )
                                if !exists {
                                    _ = try await self.b2Service.uploadImage(
                                        fileURL: companion,
                                        remotePath: remoteName,
                                        sha256: "",
                                        credentials: credentials
                                    )
                                }
                            }
                        }

                        progress.filesUploaded += 1
                        progress.currentFile = progress.filesUploaded
                        progress.currentFilename = snap.filename
                    } catch {
                        mutableItem.error = "B2 upload failed: \(snap.filename) — \(error.localizedDescription)"
                        progress.errors.append(mutableItem.error!)
                    }

                    await postUpload.send(mutableItem)
                }
                postUpload.finish()
            }
        }

        // Collect all pipeline tasks for cancellation
        let pipelineTasks: [Task<Void, Never>] = [
            feedTask, conversionTask, hashTask, encryptionTask,
            par2Task, copyTask, uploadTask
        ].compactMap { $0 }

        // MARK: - Cancellation sentinel
        // Monitors the parent Task and tears down the pipeline when cancelled.
        let sentinelTask = Task { @MainActor in
            // withTaskCancellationHandler fires immediately when the parent
            // Task is already cancelled, and also when it becomes cancelled later.
            await withTaskCancellationHandler {
                // Keep alive until cancelled — the handler does the real work.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            } onCancel: {
                // This runs synchronously on the cancelling thread.
                // Schedule the async teardown on MainActor.
                Task { @MainActor in
                    cancelFlag.withLock { $0 = true }

                    // Cancel all pipeline tasks so their loops exit
                    for task in pipelineTasks { task.cancel() }

                    // Cancel all channels: unblocks any producers stuck on
                    // backpressure and terminates all consumer for-await loops
                    for ch in allChannels {
                        await ch.cancel()
                    }
                }
            }
        }

        // MARK: - Catalog (final sink) — awaited to completion
        // Run the entire catalog sink on MainActor to avoid data races on
        // @Observable ExportProgress and to keep SwiftData access safe.
        let catalogSinkTask = Task { @MainActor [ctx, settings] in
            let modelContext = ctx.value
            let albumName = settings.albumName
            let albumYear = settings.year
            let albumMonth = settings.month
            let albumDay = settings.day
            let existingDescriptor = FetchDescriptor<AlbumRecord>(
                predicate: #Predicate {
                    $0.name == albumName && $0.year == albumYear &&
                    $0.month == albumMonth && $0.day == albumDay
                }
            )
            let albumRecord: AlbumRecord
            let isNewAlbum: Bool
            if let existing = try? modelContext.fetch(existingDescriptor).first {
                albumRecord = existing
                isNewAlbum = false
            } else {
                albumRecord = AlbumRecord(
                    name: settings.albumName,
                    year: settings.year,
                    month: settings.month,
                    day: settings.day
                )
                modelContext.insert(albumRecord)
                isNewAlbum = true
            }

            var encryptedSizes: [String: Int64] = [:]
            var catalogItemCount = 0

            progress.phase = .cataloging

            for await item in catalogCh.stream {
                await catalogCh.consumed()

                // Stop processing if cancelled — stream may still drain buffered items
                if Task.isCancelled { continue }

                guard let snap = item.snapshot else {
                    // Item has no snapshot — hash phase failed or was skipped.
                    // The error should already be in progress.errors from the hash phase,
                    // but track the drop so the completion screen can reconcile counts.
                    progress.filesDropped += 1
                    if item.error == nil {
                        progress.errors.append("Import failed: \(item.originalFilename) — unable to process file")
                    }
                    continue
                }

                if let encSize = item.encryptedSize {
                    encryptedSizes[snap.sha256] = encSize
                }

                if let record = modelContext.model(for: snap.persistentModelID) as? ImageRecord {
                    if record.album != albumRecord {
                        record.album = albumRecord
                    }
                    if !albumRecord.images.contains(record) {
                        albumRecord.images.append(record)
                    }

                    let catalogImage = CatalogImage(
                        filename: record.filename,
                        sha256: record.sha256,
                        sizeBytes: record.sizeBytes,
                        par2Filename: record.par2Filename,
                        b2FileId: record.b2FileId,
                        encryptionAlgorithm: record.isEncrypted ? "AES-256-GCM" : nil,
                        encryptionKeyId: record.encryptionKeyId,
                        encryptionNonce: record.encryptionNonce?.base64EncodedString(),
                        encryptedSizeBytes: encryptedSizes[record.sha256]
                    )
                    await catalogService.addImage(
                        catalogImage,
                        toAlbum: settings.albumName,
                        year: settings.year,
                        month: settings.month,
                        day: settings.day
                    )
                    catalogItemCount += 1
                    progress.filesCataloged = catalogItemCount
                    progress.currentFilename = snap.filename
                } else {
                    // SwiftData model lookup failed — record was inserted but can't be retrieved
                    progress.filesDropped += 1
                    progress.errors.append("Import failed: \(snap.filename) — could not save to library")
                }
            }

            // Tear down sentinel
            sentinelTask.cancel()

            if Task.isCancelled {
                if catalogItemCount == 0 && isNewAlbum {
                    modelContext.delete(albumRecord)
                }
                progress.phase = .failed
                return catalogItemCount
            }

            // Save
            do {
                try modelContext.save()
                let catalogPath = NSString(string: UserDefaults.standard.string(forKey: "catalogPath") ?? Constants.Paths.defaultCatalog).expandingTildeInPath
                try await catalogService.save(to: URL(fileURLWithPath: catalogPath))
            } catch {
                progress.errors.append("Catalog save failed: \(error.localizedDescription)")
            }

            progress.phase = .complete
            return catalogItemCount
        }

        let catalogItemCount = await catalogSinkTask.value

        if Task.isCancelled && catalogItemCount == 0 {
            throw CancellationError()
        }
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

        // pixelsWide/pixelsHigh return -1 when unknown (HEIF, RAW, etc.)
        // Fall back to the point-based image size in that case.
        let pixelWidth = srcRep.pixelsWide > 0 ? CGFloat(srcRep.pixelsWide) : image.size.width
        let pixelHeight = srcRep.pixelsHigh > 0 ? CGFloat(srcRep.pixelsHigh) : image.size.height

        guard pixelWidth > 0, pixelHeight > 0 else { return asset }

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
            return asset
        }
    }
}
