import Foundation
import SwiftData
import AppKit
import ImageIO
import CryptoKit
import os

/// Wrapper to pass MainActor-isolated values into Task closures
/// where the compiler can't prove isolation safety. Always read `.value`
/// from inside `MainActor.run { … }`.
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

/// Sendable view of a resolved import-target volume — captures only the
/// scalar fields the off-main copy stage needs. The companion `VolumeRecord`
/// references stay behind a separate `UnsafeSendable` so post-loop cleanup
/// (lastSyncedAt) can hop back to MainActor.
private struct ResolvedVolume: Sendable {
    let volumeID: String
    let label: String
    let url: URL
}

/// Import coordinator that pipelines images through phases so that
/// already-converted images can hash while later images still convert, etc.
///
/// Pipeline topology (phases skipped when disabled):
///   Import -> Conversion -> Hashing/Dedup -> Encryption -> PAR2 -> Copy -> Upload -> Catalog
///
/// All non-terminal stages run as `Task.detached` calling `nonisolated async`
/// methods on this coordinator. Heavy CPU/GPU/I/O work runs on the cooperative
/// pool; SwiftData mutations and `progress` updates hop to MainActor via
/// `MainActor.run { … }`. The catalog sink stays on MainActor because it does
/// dense SwiftData mutation per item.
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
        let staging = try makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }

        let healthCallback: @Sendable (PipelineHealth) -> Void = { health in
            Task { @MainActor in progress.health = health }
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

        try await runImportPipeline(
            assetStream: assetStream,
            staging: staging,
            photosAlbumId: photosAlbumId,
            settings: settings,
            modelContext: modelContext,
            progress: progress
        )
    }

    private func makeStagingDirectory() throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    private func runImportPipeline(
        assetStream: AsyncStream<ImportResult>,
        staging: URL,
        photosAlbumId: String,
        settings: ImportSettings,
        modelContext: ModelContext,
        progress: PhotosImportProgress
    ) async throws {
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)

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

        // Resolve volumes once. Capture Sendable scalars for the off-main copy
        // stage; keep the @Model references behind UnsafeSendable for the
        // post-loop cleanup that mutates lastSyncedAt.
        var resolvedVolumes: [ResolvedVolume] = []
        var volumeRecords: [(volumeID: String, record: VolumeRecord)] = []
        if needsCopy {
            let volumeDescriptor = FetchDescriptor<VolumeRecord>()
            let allVolumes = try modelContext.fetch(volumeDescriptor)
            for vol in allVolumes where settings.targetVolumeIDs.contains(vol.volumeID) {
                do {
                    let (url, refreshed) = try BookmarkResolver.resolveAccessAndRefresh(vol.bookmarkData)
                    if let refreshed { vol.bookmarkData = refreshed }
                    resolvedVolumes.append(ResolvedVolume(volumeID: vol.volumeID, label: vol.label, url: url))
                    volumeRecords.append((vol.volumeID, vol))
                } catch {
                    progress.errors.append("Cannot access volume: \(vol.label) — \(error.localizedDescription)")
                }
            }
        }

        // Wrap non-Sendable values for Task capture. Always read inside MainActor.run.
        let ctx = UnsafeSendable(value: modelContext)
        let volRecordsBox = UnsafeSendable(value: volumeRecords)

        // Collect all channels so we can cancel them all on teardown
        let allChannels: [any CancellableChannel] = [
            conversionCh, hashingCh, encryptionCh, par2Ch, copyCh, uploadCh, catalogCh
        ]

        // Shared lookup from sha256 → live ImageRecord. Populated during hashing,
        // used by all downstream stages instead of PersistentIdentifier lookups
        // (which fail for unsaved/temporary records). All access is on @MainActor.
        let recordsBySHA = RecordLookup()
        let candidatesLock = OSAllocatedUnfairLock(initialState: nearDuplicateCandidates)

        // MARK: - Stage launches
        // Each stage runs detached on the cooperative pool. Heavy CPU/GPU/I/O work
        // runs off-main; only progress + SwiftData touches hop to MainActor.
        let firstChannel = needsConversion ? conversionCh : hashingCh
        let feedTask = Task.detached(priority: .userInitiated) { [self] in
            await self.runFeedStage(
                assetStream: assetStream,
                firstChannel: firstChannel,
                settings: settings,
                progress: progress
            )
        }

        var conversionTask: Task<Void, Never>?
        if needsConversion {
            conversionTask = Task.detached(priority: .userInitiated) { [self] in
                await self.runConversionStage(
                    inputCh: conversionCh,
                    outputCh: postConversion,
                    settings: settings,
                    staging: staging,
                    progress: progress
                )
            }
        }

        let hashTask = Task.detached(priority: .userInitiated) { [self] in
            await self.runHashStage(
                inputCh: hashingCh,
                outputCh: postHashing,
                settings: settings,
                ctx: ctx,
                recordsBySHA: recordsBySHA,
                candidatesLock: candidatesLock,
                progress: progress
            )
        }

        var encryptionTask: Task<Void, Never>?
        if needsEncryption, let key = encKey {
            encryptionTask = Task.detached(priority: .userInitiated) { [self] in
                await self.runEncryptionStage(
                    inputCh: encryptionCh,
                    outputCh: postEncryption,
                    staging: staging,
                    encKey: key,
                    encKeyId: encKeyId,
                    recordsBySHA: recordsBySHA,
                    progress: progress
                )
            }
        }

        var par2Task: Task<Void, Never>?
        if needsPAR2 {
            par2Task = Task.detached(priority: .userInitiated) { [self] in
                await self.runPAR2Stage(
                    inputCh: par2Ch,
                    outputCh: postPAR2,
                    staging: staging,
                    cancelFlag: cancelFlag,
                    recordsBySHA: recordsBySHA,
                    progress: progress
                )
            }
        }

        var copyTask: Task<Void, Never>?
        if needsCopy {
            copyTask = Task.detached(priority: .userInitiated) { [self] in
                await self.runCopyStage(
                    inputCh: copyCh,
                    outputCh: postCopy,
                    staging: staging,
                    settings: settings,
                    resolvedVolumes: resolvedVolumes,
                    volumeRecords: volRecordsBox,
                    recordsBySHA: recordsBySHA,
                    progress: progress
                )
            }
        }

        var uploadTask: Task<Void, Never>?
        if needsUpload, let credentials = settings.b2Credentials {
            uploadTask = Task.detached(priority: .userInitiated) { [self] in
                await self.runUploadStage(
                    inputCh: uploadCh,
                    outputCh: postUpload,
                    staging: staging,
                    settings: settings,
                    credentials: credentials,
                    recordsBySHA: recordsBySHA,
                    progress: progress
                )
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

                    // Cancel all pipeline tasks so their loops exit. Detached
                    // tasks don't inherit cancellation, so this explicit cancel
                    // is what flips Task.isCancelled inside each stage body.
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
        // Stays on MainActor: dense SwiftData mutation per item.
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
                    day: settings.day,
                    photosAlbumLocalIdentifier: photosAlbumId
                )
                modelContext.insert(albumRecord)
                isNewAlbum = true
            }
            // Backfill identifier on legacy albums on re-import.
            if albumRecord.photosAlbumLocalIdentifier == nil {
                albumRecord.photosAlbumLocalIdentifier = photosAlbumId
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
                try await catalogService.save(to: Constants.Paths.resolvedCatalogURL)
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

    /// Apply a precomputed Photos delta to an album: remove catalog images
    /// whose source PHAssets are gone, then import the new PHAssets.
    ///
    /// `mountedVolumes` and `b2Credentials` are required only for removals;
    /// pass empty / nil if the delta has no removals or you don't want to
    /// touch external storage for them.
    func resyncAlbum(
        albumRecord: AlbumRecord,
        delta: AlbumDelta,
        settings: ImportSettings,
        modelContext: ModelContext,
        progress: PhotosImportProgress,
        mountedVolumes: [(volumeID: String, mountURL: URL)] = [],
        b2Credentials: B2Credentials? = nil
    ) async throws {
        // Inherit album coordinates so the catalog sink updates the existing
        // AlbumRecord rather than creating a new one.
        var albumSettings = settings
        albumSettings.albumName = albumRecord.name
        albumSettings.year = albumRecord.year
        albumSettings.month = albumRecord.month
        albumSettings.day = albumRecord.day

        // 1. Removals (best-effort — collect errors, continue to additions).
        if !delta.removed.isEmpty {
            let albumPath = "\(albumRecord.year)/\(albumRecord.month)/\(albumRecord.day)/\(albumRecord.name)"
            let inputs = delta.removed.map { image in
                DeletionService.ImageDeletionInput(
                    sha256: image.sha256,
                    filename: image.filename,
                    par2Filename: image.par2Filename,
                    b2FileId: image.b2FileId,
                    storageLocations: image.storageLocations,
                    albumPath: albumPath
                )
            }

            let delService = DeletionService()
            let delProgress = DeletionProgress()
            let result = await delService.deleteImageFiles(
                images: inputs,
                mountedVolumes: mountedVolumes,
                b2Credentials: b2Credentials,
                progress: delProgress,
                entireAlbum: false
            )

            for err in result.errors {
                progress.errors.append(err)
            }

            // Catalog + SwiftData cleanup
            for image in delta.removed {
                await catalogService.removeImage(
                    sha256: image.sha256,
                    fromAlbum: albumRecord.name,
                    year: albumRecord.year,
                    month: albumRecord.month,
                    day: albumRecord.day
                )
                await thumbnailService.removeThumbnails(for: image.sha256)
                modelContext.delete(image)
            }
            try? modelContext.save()
        }

        // 2. Additions through the standard pipeline.
        if !delta.added.isEmpty {
            let staging = try makeStagingDirectory()
            defer { try? FileManager.default.removeItem(at: staging) }

            let healthCallback: @Sendable (PipelineHealth) -> Void = { health in
                Task { @MainActor in progress.health = health }
            }
            let assetStream = try await photosService.importAssetsStreaming(
                assets: delta.added,
                to: staging,
                callbacks: PhotosImportCallbacks(health: healthCallback)
            ) { current, total in
                Task { @MainActor in
                    progress.currentFile = current
                    progress.totalFiles = total
                }
            }

            try await runImportPipeline(
                assetStream: assetStream,
                staging: staging,
                photosAlbumId: albumRecord.photosAlbumLocalIdentifier ?? "",
                settings: albumSettings,
                modelContext: modelContext,
                progress: progress
            )
        } else {
            // No additions — make sure the catalog reflects any deletions we made.
            try? await catalogService.save(to: Constants.Paths.resolvedCatalogURL)
            await MainActor.run { progress.phase = .complete }
        }
    }

    // MARK: - Stage implementations (off-main)

    /// Streams from the Photos import into the first pipeline channel.
    private nonisolated func runFeedStage(
        assetStream: AsyncStream<ImportResult>,
        firstChannel: AsyncChannel<PipelineItem>,
        settings: ImportSettings,
        progress: PhotosImportProgress
    ) async {
        defer { firstChannel.finish() }
        for await result in assetStream {
            if Task.isCancelled { break }
            switch result {
            case .success(let asset):
                let item = PipelineItem(
                    albumName: settings.albumName,
                    importDate: .now,
                    fileURL: asset.fileURL,
                    originalFilename: asset.originalFilename,
                    phAssetLocalIdentifier: asset.phAssetLocalIdentifier
                )
                await firstChannel.send(item)
            case .failure(_, let error):
                let msg = "Photos export failed: \(error)"
                await MainActor.run {
                    progress.errors.append(msg)
                    progress.filesDropped += 1
                }
            case .skipped(_, _, let reason):
                await MainActor.run {
                    progress.filesSkipped += 1
                    progress.skipReasons[reason, default: 0] += 1
                }
            }
        }
    }

    /// Decodes/re-encodes/resizes images. CPU-heavy work runs off-main.
    private nonisolated func runConversionStage(
        inputCh: AsyncChannel<PipelineItem>,
        outputCh: AsyncChannel<PipelineItem>,
        settings: ImportSettings,
        staging: URL,
        progress: PhotosImportProgress
    ) async {
        defer { outputCh.finish() }
        await MainActor.run { progress.phase = .converting }

        for await item in inputCh.stream {
            await inputCh.consumed()
            if Task.isCancelled { break }

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
            let fname = item.originalFilename
            await MainActor.run {
                progress.filesConverted += 1
                progress.currentFile = progress.filesConverted
                progress.currentFilename = fname
            }
            await outputCh.send(mutableItem)
        }
    }

    /// Hash + dedup. SHA-256 runs on the hasher actor; perceptual hash and
    /// near-dup scan run off-main. SwiftData fetch+insert is batched into one
    /// MainActor.run per item to preserve fetch-then-insert atomicity.
    private nonisolated func runHashStage(
        inputCh: AsyncChannel<PipelineItem>,
        outputCh: AsyncChannel<PipelineItem>,
        settings: ImportSettings,
        ctx: UnsafeSendable<ModelContext>,
        recordsBySHA: RecordLookup,
        candidatesLock: OSAllocatedUnfairLock<[(sha256: String, filename: String, hash: Data)]>,
        progress: PhotosImportProgress
    ) async {
        defer { outputCh.finish() }
        await MainActor.run {
            progress.phase = .hashing
            progress.currentFile = 0
        }

        for await item in inputCh.stream {
            await inputCh.consumed()
            if Task.isCancelled { break }

            var mutableItem = item
            let fileToHash = item.convertedURL ?? item.fileURL
            do {
                let (hash, size) = try await self.hasher.sha256AndSize(of: fileToHash)
                mutableItem.sha256 = hash
                mutableItem.sizeBytes = size

                let phAssetId = item.phAssetLocalIdentifier
                // Atomic dedup decision on main: check batch first, then DB.
                let existing: (filename: String, sizeBytes: Int64)? = try await MainActor.run {
                    let modelContext = ctx.value
                    if let batchRecord = recordsBySHA[hash] {
                        if batchRecord.phAssetLocalIdentifier == nil, let id = phAssetId {
                            batchRecord.phAssetLocalIdentifier = id
                        }
                        return (batchRecord.filename, batchRecord.sizeBytes)
                    }
                    let descriptor = FetchDescriptor<ImageRecord>(
                        predicate: #Predicate { $0.sha256 == hash }
                    )
                    let dbResults = try modelContext.fetch(descriptor)
                    if let dbRecord = dbResults.first {
                        if dbRecord.phAssetLocalIdentifier == nil, let id = phAssetId {
                            dbRecord.phAssetLocalIdentifier = id
                        }
                        recordsBySHA[hash] = dbRecord
                        return (dbRecord.filename, dbRecord.sizeBytes)
                    }
                    return nil
                }

                if let existing {
                    mutableItem.isDuplicate = true
                    mutableItem.snapshot = ImageRecordSnapshot(
                        sha256: hash,
                        filename: existing.filename,
                        sizeBytes: existing.sizeBytes,
                        isNew: false
                    )
                    await MainActor.run { progress.filesDeduplicated += 1 }
                } else {
                    // Brand-new record. Heavy work off-main:
                    //   1. thumbnail (already on thumbnail actor)
                    //   2. perceptual hash (CPU)
                    //   3. near-dup scan (CPU + thread-safe lock)
                    try? await self.thumbnailService.generateThumbnail(for: fileToHash, sha256: hash)
                    let pHash = try? PerceptualHash.compute(for: fileToHash)
                    if let pHash {
                        mutableItem.perceptualHash = pHash
                    }

                    var nearDupMatch: NearDuplicateMatch?
                    if settings.detectNearDuplicates, let pHash {
                        let originalFilename = item.originalFilename
                        let candidates = candidatesLock.withLock { $0 }
                        for candidate in candidates {
                            let distance = PerceptualHash.hammingDistance(pHash, candidate.hash)
                            if distance < settings.nearDuplicateThreshold {
                                nearDupMatch = NearDuplicateMatch(
                                    newFilename: originalFilename,
                                    newSha256: hash,
                                    existingFilename: candidate.filename,
                                    existingSha256: candidate.sha256,
                                    hammingDistance: distance
                                )
                                break
                            }
                        }
                        candidatesLock.withLock {
                            $0.append((hash, originalFilename, pHash))
                        }
                    }

                    let activeFilename = item.activeFilename
                    let pHashCopy = pHash
                    let matchToAppend = nearDupMatch
                    await MainActor.run {
                        let modelContext = ctx.value
                        let record = ImageRecord(
                            sha256: hash,
                            filename: activeFilename,
                            sizeBytes: size,
                            phAssetLocalIdentifier: phAssetId
                        )
                        record.thumbnailState = .generated
                        if let pHashCopy {
                            record.perceptualHash = pHashCopy
                        }
                        if let matchToAppend {
                            progress.nearDuplicates.append(matchToAppend)
                            progress.nearDuplicatesFound += 1
                        }
                        modelContext.insert(record)
                        recordsBySHA[hash] = record
                    }
                    mutableItem.snapshot = ImageRecordSnapshot(
                        sha256: hash,
                        filename: activeFilename,
                        sizeBytes: size,
                        isNew: true
                    )
                }
            } catch {
                let errMsg = "Hash failed: \(item.originalFilename) — \(error.localizedDescription)"
                mutableItem.error = errMsg
                await MainActor.run { progress.errors.append(errMsg) }
            }

            let fname = item.originalFilename
            await MainActor.run {
                progress.filesHashed += 1
                progress.currentFile = progress.filesHashed
                progress.currentFilename = fname
            }
            await outputCh.send(mutableItem)
        }
    }

    /// Encrypts new files. Synchronous AES-GCM runs off-main.
    private nonisolated func runEncryptionStage(
        inputCh: AsyncChannel<PipelineItem>,
        outputCh: AsyncChannel<PipelineItem>,
        staging: URL,
        encKey: SymmetricKey,
        encKeyId: String?,
        recordsBySHA: RecordLookup,
        progress: PhotosImportProgress
    ) async {
        defer { outputCh.finish() }
        await MainActor.run {
            progress.phase = .encrypting
            progress.currentFile = 0
        }

        for await item in inputCh.stream {
            await inputCh.consumed()
            if Task.isCancelled { break }

            var mutableItem = item
            guard let snap = item.snapshot, item.error == nil, snap.isNew else {
                await outputCh.send(mutableItem)
                continue
            }

            let encryptedURL = staging.appendingPathComponent(snap.filename + ".enc")
            do {
                let (nonce, encSize) = try EncryptionService.encryptFileWithKey(
                    at: item.activeFileURL, to: encryptedURL, sha256: snap.sha256, key: encKey
                )
                mutableItem.encryptedURL = encryptedURL
                mutableItem.encryptionNonce = nonce
                mutableItem.encryptedSize = encSize

                let sha = snap.sha256
                let fname = snap.filename
                await MainActor.run {
                    if let record = recordsBySHA[sha] {
                        record.isEncrypted = true
                        record.encryptionNonce = nonce
                        record.encryptionKeyId = encKeyId
                    }
                    progress.filesEncrypted += 1
                    progress.currentFile = progress.filesEncrypted
                    progress.currentFilename = fname
                }
            } catch {
                let errMsg = "Encrypt failed: \(snap.filename) — \(error.localizedDescription)"
                mutableItem.error = errMsg
                await MainActor.run { progress.errors.append(errMsg) }
            }

            await outputCh.send(mutableItem)
        }
    }

    /// Generates PAR2 recovery data. File I/O, Reed-Solomon math, and Metal
    /// dispatch all run off-main; the per-file `onProgress` callback hops
    /// back to MainActor explicitly.
    private nonisolated func runPAR2Stage(
        inputCh: AsyncChannel<PipelineItem>,
        outputCh: AsyncChannel<PipelineItem>,
        staging: URL,
        cancelFlag: OSAllocatedUnfairLock<Bool>,
        recordsBySHA: RecordLookup,
        progress: PhotosImportProgress
    ) async {
        defer { outputCh.finish() }
        await MainActor.run {
            progress.phase = .par2
            progress.currentFile = 0
        }

        for await item in inputCh.stream {
            await inputCh.consumed()
            if Task.isCancelled { break }

            var mutableItem = item
            guard let snap = item.snapshot, item.error == nil, snap.isNew else {
                await outputCh.send(mutableItem)
                continue
            }

            let snapFilename = snap.filename
            await MainActor.run {
                progress.currentFilename = snapFilename
                progress.par2FileFraction = 0
            }

            do {
                let par2URL = try self.redundancyService.generatePAR2(
                    for: item.activeFileURL,
                    outputDirectory: staging,
                    onProgress: { fraction in
                        Task { @MainActor in
                            progress.par2FileFraction = fraction
                        }
                    },
                    cancelFlag: cancelFlag
                )
                mutableItem.par2Filename = par2URL.lastPathComponent
                mutableItem.par2URL = par2URL

                let sha = snap.sha256
                let par2Name = par2URL.lastPathComponent
                await MainActor.run {
                    if let record = recordsBySHA[sha] {
                        record.par2Filename = par2Name
                    }
                    progress.filesProtected += 1
                    progress.currentFile += 1
                }
            } catch {
                let errMsg = "PAR2 failed: \(snap.filename) — \(error.localizedDescription)"
                mutableItem.error = errMsg
                await MainActor.run {
                    progress.errors.append(errMsg)
                    progress.currentFile += 1
                }
            }

            await outputCh.send(mutableItem)
        }
    }

    /// Copies files (and PAR2 companions) to external volumes. Per-file I/O
    /// runs off-main. Volume cleanup (lastSyncedAt + stop access) runs after
    /// the loop and is MainActor.run-non-cancellable so it always completes.
    private nonisolated func runCopyStage(
        inputCh: AsyncChannel<PipelineItem>,
        outputCh: AsyncChannel<PipelineItem>,
        staging: URL,
        settings: ImportSettings,
        resolvedVolumes: [ResolvedVolume],
        volumeRecords: UnsafeSendable<[(volumeID: String, record: VolumeRecord)]>,
        recordsBySHA: RecordLookup,
        progress: PhotosImportProgress
    ) async {
        defer { outputCh.finish() }
        await MainActor.run {
            progress.phase = .copying
            progress.currentFile = 0
        }

        for await item in inputCh.stream {
            await inputCh.consumed()
            if Task.isCancelled { break }

            var mutableItem = item
            guard let snap = item.snapshot, item.error == nil else {
                await outputCh.send(mutableItem)
                continue
            }

            let sourceFile = item.activeFileURL
            var newLocations: [StorageLocation] = []
            var copyErrors: [String] = []

            for vol in resolvedVolumes {
                let destBase = vol.url
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
                    let location = StorageLocation(volumeID: vol.volumeID, relativePath: relativePath)
                    if !mutableItem.storageLocations.contains(location) {
                        mutableItem.storageLocations.append(location)
                    }
                    newLocations.append(location)

                    // Copy PAR2 companion files (index + vol)
                    if !item.par2Filename.isEmpty {
                        let companions = RedundancyService.companionFiles(
                            forIndex: item.par2Filename, in: staging
                        )
                        for companion in companions {
                            let cdest = destBase.appendingPathComponent(companion.lastPathComponent)
                            if !FileManager.default.fileExists(atPath: cdest.path) {
                                try FileManager.default.copyItem(at: companion, to: cdest)
                            }
                        }
                    }
                } catch {
                    copyErrors.append("Copy failed: \(snap.filename) to \(vol.label) — \(error.localizedDescription)")
                }
            }

            // Mirror original behavior: mutableItem.error reflects the last per-volume failure.
            if let lastErr = copyErrors.last {
                mutableItem.error = lastErr
            }

            let sha = snap.sha256
            let locsToAppend = newLocations
            let errsToAppend = copyErrors
            await MainActor.run {
                if let record = recordsBySHA[sha] {
                    for location in locsToAppend {
                        if !record.storageLocations.contains(location) {
                            record.storageLocations.append(location)
                        }
                    }
                }
                for err in errsToAppend {
                    progress.errors.append(err)
                }
                progress.filesCopied += 1
            }

            await outputCh.send(mutableItem)
        }

        // Cleanup runs whether the loop ended naturally or via cancellation.
        await MainActor.run {
            for (_, volRecord) in volumeRecords.value {
                volRecord.lastSyncedAt = .now
            }
        }
        for vol in resolvedVolumes {
            vol.url.stopAccessingSecurityScopedResource()
        }
    }

    /// Uploads to B2. Network I/O is already async; only progress + record
    /// mutations need MainActor hops.
    private nonisolated func runUploadStage(
        inputCh: AsyncChannel<PipelineItem>,
        outputCh: AsyncChannel<PipelineItem>,
        staging: URL,
        settings: ImportSettings,
        credentials: B2Credentials,
        recordsBySHA: RecordLookup,
        progress: PhotosImportProgress
    ) async {
        defer { outputCh.finish() }
        await MainActor.run {
            progress.phase = .uploading
            progress.currentFile = 0
        }

        for await item in inputCh.stream {
            await inputCh.consumed()
            if Task.isCancelled { break }

            var mutableItem = item
            guard let snap = item.snapshot, item.error == nil else {
                await outputCh.send(mutableItem)
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
                    let sha = snap.sha256
                    await MainActor.run {
                        if let record = recordsBySHA[sha] {
                            record.b2FileId = fileId
                        }
                    }
                } else {
                    let sha = snap.sha256
                    let needsBackfill: Bool = await MainActor.run {
                        if let record = recordsBySHA[sha], record.b2FileId == nil {
                            return true
                        }
                        return false
                    }
                    if needsBackfill {
                        let listings = try await self.b2Service.listAllFiles(
                            bucketId: credentials.bucketId,
                            credentials: credentials,
                            prefix: remotePath
                        )
                        if let listing = listings.first(where: { $0.fileName == remotePath }) {
                            let fileId = listing.fileId
                            await MainActor.run {
                                if let record = recordsBySHA[sha] {
                                    record.b2FileId = fileId
                                }
                            }
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

                let fname = snap.filename
                await MainActor.run {
                    progress.filesUploaded += 1
                    progress.currentFile = progress.filesUploaded
                    progress.currentFilename = fname
                }
            } catch {
                let errMsg = error.localizedDescription
                mutableItem.error = errMsg
                await MainActor.run { progress.errors.append(errMsg) }
            }

            await outputCh.send(mutableItem)
        }
    }
}
