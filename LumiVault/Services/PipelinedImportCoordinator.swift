import Foundation
import SwiftData
import AppKit
import ImageIO
import os

/// Wrapper to pass MainActor-isolated values into @MainActor Task closures
/// where the compiler can't prove isolation safety.
private struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
}

/// Mutable dictionary wrapper that is @unchecked Sendable.
/// All access must be on @MainActor.
private final class RecordLookup: @unchecked Sendable {
    var records: [String: ImageRecord] = [:]
    subscript(sha256: String) -> ImageRecord? {
        get { records[sha256] }
        set { records[sha256] = newValue }
    }
}

/// Import coordinator that pipelines images through phases so that
/// already-converted images can hash while later images still convert, etc.
///
/// Pipeline topology (phases skipped when disabled):
///   Import -> Conversion -> Hashing/Dedup -> Encryption -> PAR2 -> Copy -> Upload -> Catalog
class PipelinedImportCoordinator: @unchecked Sendable {
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

    func importAlbum(
        photosAlbumId: String,
        settings: ImportSettings,
        modelContext: ModelContext,
        progress: PhotosImportProgress
    ) async throws {
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)

        // Staging directory
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // Determine active phases
        let needsConversion = settings.imageFormat != .original || settings.maxDimension != .original
        let encryptionKeyAvailable = await encryptionService.isKeyAvailable
        let needsEncryption = settings.encryptFiles && encryptionKeyAvailable
        let needsPAR2 = settings.generatePAR2
        let needsCopy = !settings.targetVolumeIDs.isEmpty
        let needsUpload = settings.uploadToB2 && settings.b2Credentials != nil

        await MainActor.run {
            progress.phase = .importing
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
                do {
                    let (url, refreshed) = try BookmarkResolver.resolveAccessAndRefresh(vol.bookmarkData)
                    if let refreshed { vol.bookmarkData = refreshed }
                    resolvedVolumes.append((vol, url))
                } catch {
                    progress.errors.append("Cannot access volume: \(vol.label) — \(error.localizedDescription)")
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

        // 1. Import from Photos — stream assets directly into the pipeline
        let healthCallback: @Sendable (PipelineHealth) -> Void = { health in
            Task { @MainActor in
                progress.health = health
            }
        }
        let assetStream = try await photosService.importAlbumStreaming(
            albumId: photosAlbumId,
            to: staging,
            callbacks: PhotosImportCallbacks(health: healthCallback)
        ) { current, total in
            Task { @MainActor in
                progress.currentFile = current
                progress.totalFiles = total
            }
        }

        // Shared lookup from sha256 → live ImageRecord. Populated during hashing,
        // used by all downstream stages instead of PersistentIdentifier lookups
        // (which fail for unsaved/temporary records). All access is on @MainActor.
        let recordsBySHA = RecordLookup()

        // MARK: - Feed (streams from Photos import into the first pipeline channel)
        let firstChannel = needsConversion ? conversionCh : hashingCh
        let feedTask = Task { @MainActor [settings] in
            defer { firstChannel.finish() }
            for await result in assetStream {
                guard !Task.isCancelled else { break }
                switch result {
                case .success(let asset):
                    let item = PipelineItem(
                        albumName: settings.albumName,
                        importDate: .now,
                        fileURL: asset.fileURL,
                        originalFilename: asset.originalFilename
                    )
                    await firstChannel.send(item)
                case .failure(_, let error):
                    progress.errors.append("Photos export failed: \(error)")
                    progress.filesDropped += 1
                case .skipped(_, _, let reason):
                    progress.filesSkipped += 1
                    progress.skipReasons[reason, default: 0] += 1
                }
            }
        }

        // MARK: - Conversion
        var conversionTask: Task<Void, Never>?
        if needsConversion {
            conversionTask = Task { @MainActor [settings] in
                defer { postConversion.finish() }
                progress.phase = .converting

                for await item in conversionCh.stream {
                    await conversionCh.consumed()
                    guard !Task.isCancelled else { break }

                    var mutableItem = item
                    let converted = ImageConversionService.convertImage(
                        asset: ImportedAsset(
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
                        mutableItem.convertedFilename = converted.originalFilename
                    }
                    progress.filesConverted += 1
                    progress.currentFile = progress.filesConverted
                    progress.currentFilename = item.originalFilename

                    await postConversion.send(mutableItem)
                }
            }
        }

        // MARK: - Hashing & Dedup
        let candidatesLock = OSAllocatedUnfairLock(initialState: nearDuplicateCandidates)

        let hashTask = Task { @MainActor [ctx, settings] in
            defer { postHashing.finish() }
            let modelContext = ctx.value
            progress.phase = .hashing
            progress.currentFile = 0

            for await item in hashingCh.stream {
                await hashingCh.consumed()
                guard !Task.isCancelled else { break }

                var mutableItem = item
                let fileToHash = item.convertedURL ?? item.fileURL
                do {
                    let (hash, size) = try await self.hasher.sha256AndSize(of: fileToHash)
                    mutableItem.sha256 = hash
                    mutableItem.sizeBytes = size

                    // Check our own batch first (pending inserts may not appear in fetch)
                    if let batchRecord = recordsBySHA[hash] {
                        mutableItem.isDuplicate = true
                        mutableItem.snapshot = ImageRecordSnapshot(
                            sha256: hash,
                            filename: batchRecord.filename,
                            sizeBytes: batchRecord.sizeBytes,
                            isNew: false
                        )
                        progress.filesDeduplicated += 1
                    } else {
                        let descriptor = FetchDescriptor<ImageRecord>(
                            predicate: #Predicate { $0.sha256 == hash }
                        )
                        let existing = try modelContext.fetch(descriptor)

                        if let existingRecord = existing.first {
                            mutableItem.isDuplicate = true
                            recordsBySHA[hash] = existingRecord
                            mutableItem.snapshot = ImageRecordSnapshot(
                                sha256: hash,
                                filename: existingRecord.filename,
                                sizeBytes: existingRecord.sizeBytes,
                                isNew: false
                            )
                            progress.filesDeduplicated += 1
                        } else {
                            let record = ImageRecord(
                                sha256: hash,
                                filename: item.activeFilename,
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
                            recordsBySHA[hash] = record
                            mutableItem.snapshot = ImageRecordSnapshot(
                                sha256: hash,
                                filename: item.activeFilename,
                                sizeBytes: size,
                                isNew: true
                            )
                        }
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
        }

        // MARK: - Encryption
        var encryptionTask: Task<Void, Never>?
        if needsEncryption, let key = encKey {
            encryptionTask = Task { @MainActor in
                defer { postEncryption.finish() }
                progress.phase = .encrypting
                progress.currentFile = 0

                for await item in encryptionCh.stream {
                    await encryptionCh.consumed()
                    guard !Task.isCancelled else { break }

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

                        if let record = recordsBySHA[snap.sha256] {
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
            }
        }

        // MARK: - PAR2
        var par2Task: Task<Void, Never>?
        if needsPAR2 {
            par2Task = Task { @MainActor in
                defer { postPAR2.finish() }
                progress.phase = .par2
                progress.currentFile = 0

                for await item in par2Ch.stream {
                    await par2Ch.consumed()
                    guard !Task.isCancelled else { break }

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

                        if let record = recordsBySHA[snap.sha256] {
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
            }
        }

        // MARK: - Copy to Volumes
        var copyTask: Task<Void, Never>?
        if needsCopy {
            copyTask = Task { @MainActor [vols, settings] in
                defer { postCopy.finish() }
                let resolvedVolumes = vols.value
                progress.phase = .copying
                progress.currentFile = 0

                for await item in copyCh.stream {
                    await copyCh.consumed()
                    guard !Task.isCancelled else { break }

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

                            if let record = recordsBySHA[snap.sha256] {
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
            }
        }

        // MARK: - B2 Upload
        var uploadTask: Task<Void, Never>?
        if needsUpload, let credentials = settings.b2Credentials {
            uploadTask = Task { @MainActor in
                defer { postUpload.finish() }
                progress.phase = .uploading
                progress.currentFile = 0

                for await item in uploadCh.stream {
                    await uploadCh.consumed()
                    guard !Task.isCancelled else { break }

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
                            let uploadOnAttempt: @Sendable (Int) -> Void = { attempt in
                                Task { @MainActor in
                                    if attempt == 0 {
                                        progress.health = .normal
                                    } else {
                                        progress.health = .slow(.b2Retrying(attempt: attempt))
                                    }
                                }
                            }
                            let fileId = try await self.b2Service.uploadImage(
                                fileURL: item.activeFileURL,
                                remotePath: remotePath,
                                sha256: snap.sha256,
                                credentials: credentials,
                                onAttempt: uploadOnAttempt
                            )
                            mutableItem.b2FileId = fileId
                            if let record = recordsBySHA[snap.sha256] {
                                record.b2FileId = fileId
                            }
                        } else {
                            if let record = recordsBySHA[snap.sha256],
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
                        mutableItem.error = error.localizedDescription
                        progress.errors.append(mutableItem.error!)
                    }

                    await postUpload.send(mutableItem)
                }
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
        // @Observable PhotosImportProgress and to keep SwiftData access safe.
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

                // Stop processing if cancelled — break immediately instead of draining buffer
                if Task.isCancelled { break }

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

                if let record = recordsBySHA[snap.sha256] {
                    let isNewToAlbum: Bool
                    if record.album != albumRecord {
                        record.album = albumRecord
                        isNewToAlbum = true
                    } else {
                        isNewToAlbum = !albumRecord.images.contains(record)
                    }
                    if isNewToAlbum && !albumRecord.images.contains(record) {
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

                    if isNewToAlbum {
                        catalogItemCount += 1
                    } else {
                        progress.filesDeduplicated += 1
                    }
                    progress.filesCataloged = catalogItemCount
                    progress.currentFilename = snap.filename
                } else {
                    // Record not found in lookup — should not happen
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

}
