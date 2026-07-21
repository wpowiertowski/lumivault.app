import Foundation
import Photos
import AVFoundation
import UniformTypeIdentifiers
import os

struct PhotosAlbum: Identifiable, Sendable {
    let id: String
    let title: String
    /// Image assets in the album. Named for its original image-only meaning;
    /// videos are counted separately in `videoCount`.
    let assetCount: Int
    let videoCount: Int
    let startDate: Date?
    let endDate: Date?

    nonisolated init(id: String, title: String, assetCount: Int, videoCount: Int = 0, startDate: Date?, endDate: Date?) {
        self.id = id
        self.title = title
        self.assetCount = assetCount
        self.videoCount = videoCount
        self.startDate = startDate
        self.endDate = endDate
    }
}

struct ImportedAsset: Sendable {
    let fileURL: URL
    let originalFilename: String
    let creationDate: Date?
    let phAssetLocalIdentifier: String?
    let mediaType: MediaType

    nonisolated init(
        fileURL: URL,
        originalFilename: String,
        creationDate: Date?,
        phAssetLocalIdentifier: String? = nil,
        mediaType: MediaType = .image
    ) {
        self.fileURL = fileURL
        self.originalFilename = originalFilename
        self.creationDate = creationDate
        self.phAssetLocalIdentifier = phAssetLocalIdentifier
        self.mediaType = mediaType
    }
}

enum ImportResult: Sendable {
    case success(ImportedAsset)
    case failure(assetIndex: Int, error: String)
    case skipped(assetIndex: Int, filename: String, reason: String)
}

/// Coordinator hooks the pipeline into the service to surface non-error health status.
struct PhotosImportCallbacks: Sendable {
    /// Called when the current operation's health state changes (slow ↔ normal).
    var health: @Sendable (PipelineHealth) -> Void = { _ in }
}

actor PhotosImportService {

    // MARK: - Process-global concurrency gate
    //
    // `PHAssetResourceManager.default()` is a singleton shared across the
    // entire process. Unbounded concurrent `requestData` calls have been
    // observed to wedge assetsd (46104 "resource unavailable" XPC errors).
    // Serializing every resource request keeps assetsd's per-client request
    // budget healthy regardless of how many importers exist.
    nonisolated static let gate = AsyncSemaphore(count: 1)

    // MARK: - Authorization

    nonisolated func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - Media Scope

    /// Predicate matching what the import pipeline ingests. The album picker,
    /// median-date computation, library monitor, and import fetch must all use
    /// this one helper so counts and sync badges can never drift from the
    /// actual import scope.
    nonisolated static func mediaPredicate(includeVideos: Bool) -> NSPredicate {
        if includeVideos {
            return NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )
        }
        return NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    }

    // MARK: - Album Enumeration

    func fetchAlbums() -> [PhotosAlbum] {
        var albums: [PhotosAlbum] = []

        // Images and videos counted separately — the picker shows both, and
        // `assetCount` keeps its image-only meaning for sort/sync parity.
        let imageOnly = PHFetchOptions()
        imageOnly.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let videoOnly = PHFetchOptions()
        videoOnly.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)

        // User-created albums
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil
        )
        userAlbums.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: imageOnly)
            let videos = PHAsset.fetchAssets(in: collection, options: videoOnly)
            albums.append(PhotosAlbum(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled",
                assetCount: assets.count,
                videoCount: videos.count,
                startDate: collection.startDate,
                endDate: collection.endDate
            ))
        }

        // Smart albums (Favorites, Recently Added, etc.)
        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .any, options: nil
        )
        smartAlbums.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: imageOnly)
            let videos = PHAsset.fetchAssets(in: collection, options: videoOnly)
            guard assets.count + videos.count > 0 else { return }
            albums.append(PhotosAlbum(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled",
                assetCount: assets.count,
                videoCount: videos.count,
                startDate: collection.startDate,
                endDate: collection.endDate
            ))
        }

        return albums
    }

    /// Median `creationDate` across the album's assets in the import scope.
    /// `creationDate` is the original capture timestamp on the PHAsset, distinct
    /// from the edit/modification date (`modificationDate`). Returns nil if the
    /// album is missing or contains no in-scope assets with creation dates.
    ///
    /// The media-type filter matches what the import pipeline actually ingests —
    /// out-of-scope assets in the same Photos album won't skew the result.
    func medianCreationDate(in albumLocalIdentifier: String, includeVideos: Bool = ImportSettings.includeVideosDefault) -> Date? {
        let fetchResult = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumLocalIdentifier], options: nil
        )
        guard let collection = fetchResult.firstObject else { return nil }

        let opts = PHFetchOptions()
        opts.predicate = Self.mediaPredicate(includeVideos: includeVideos)
        let assets = PHAsset.fetchAssets(in: collection, options: opts)

        var dates: [Date] = []
        dates.reserveCapacity(assets.count)
        for i in 0..<assets.count {
            if let date = assets.object(at: i).creationDate {
                dates.append(date)
            }
        }
        guard !dates.isEmpty else { return nil }
        dates.sort()
        return dates[dates.count / 2]
    }

    // MARK: - Album Asset Diff

    /// Returns the current in-scope PHAssets in the named album, or `nil` if the
    /// album is no longer present (e.g. the user deleted it in Photos). Defaults
    /// to the user's Import Defaults media scope so album diffs (sync badges,
    /// resync) match what an import would ingest.
    func fetchAssets(in albumLocalIdentifier: String, includeVideos: Bool = ImportSettings.includeVideosDefault) -> [PHAsset]? {
        let fetchResult = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumLocalIdentifier], options: nil
        )
        guard let collection = fetchResult.firstObject else { return nil }

        let opts = PHFetchOptions()
        opts.predicate = Self.mediaPredicate(includeVideos: includeVideos)
        let assets = PHAsset.fetchAssets(in: collection, options: opts)

        var refs: [PHAsset] = []
        refs.reserveCapacity(assets.count)
        for i in 0..<assets.count {
            refs.append(assets.object(at: i))
        }
        return refs
    }

    /// For each album id, how many of its current image assets are already
    /// tracked in the catalog (present in `trackedIds`). Computed from the
    /// album's live Photos asset ids intersected with the global tracked set, so
    /// it stays correct when byte-identical duplicates dedup to a single stored
    /// image owned by a different album — counting a record's ids per owning
    /// album miscounts both albums in that case.
    func importedAssetCounts(albumIds: [String], trackedIds: Set<String>) -> [String: Int] {
        var result: [String: Int] = [:]
        for albumId in albumIds {
            guard let assets = fetchAssets(in: albumId) else { continue }
            result[albumId] = assets.reduce(0) { count, asset in
                count + (trackedIds.contains(asset.localIdentifier) ? 1 : 0)
            }
        }
        return result
    }

    // MARK: - Single Asset Import

    private func importAsset(
        _ asset: PHAsset,
        to directory: URL,
        callbacks: PhotosImportCallbacks
    ) async throws -> ImportedAsset {
        let resources = PHAssetResource.assetResources(for: asset)
        let isVideo = asset.mediaType == .video
        let mediaType: MediaType = isVideo ? .video : .image

        // Prefer edited (fullSizePhoto / fullSizeVideo) over the unedited
        // original so that user edits from Photos are preserved in the import.
        // Live Photo `.pairedVideo` resources are never selected — a Live Photo
        // has mediaType == .image and imports as its still.
        let editedType: PHAssetResourceType = isVideo ? .fullSizeVideo : .fullSizePhoto
        let originalType: PHAssetResourceType = isVideo ? .video : .photo
        guard let resource = resources.first(where: { $0.type == editedType })
                ?? resources.first(where: { $0.type == originalType })
                ?? resources.first else {
            throw PhotosImportError.noResourceFound
        }

        // Use the original resource's filename (full-size renders report generic
        // names like "FullSizeRender.jpeg" / "FullSizeRender.mov")
        let originalResource = resources.first(where: { $0.type == originalType })
        let filename = originalResource?.originalFilename ?? resource.originalFilename

        // Edited asset whose rendered version isn't available as a resource
        // (typical when the edit was made on another device and iCloud hasn't
        // materialized the render locally — and, for videos, always the case
        // for slow-mo, whose current version exists only as an AVComposition).
        // Exporting the original resource would silently drop the edit — and
        // collapse differently-edited duplicates into one SHA-256 — so render
        // the current version instead.
        if resource.type != editedType,
           resources.contains(where: { $0.type == .adjustmentData }) {
            do {
                if isVideo {
                    return try await importRenderedVideo(asset, originalFilename: filename, to: directory)
                }
                return try await importRenderedAsset(asset, originalFilename: filename, to: directory)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The render couldn't be produced (offline, edit not yet
                // materialized, or the request stalled). Fall through to the
                // original resource so the asset is still archived in its
                // unedited form rather than dropped entirely — the edit is lost,
                // but the media is preserved.
                Logger(subsystem: "app.lumivault", category: "import").warning(
                    "Render unavailable for \(filename, privacy: .public); importing original instead. \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let destURL = directory.appendingPathComponent(filename)

        // Handle filename collisions
        let finalURL = uniqueURL(for: destURL)

        try await writeResourceWithRetry(resource, to: finalURL, filename: filename, callbacks: callbacks)

        return ImportedAsset(
            fileURL: finalURL,
            originalFilename: filename,
            creationDate: asset.creationDate,
            phAssetLocalIdentifier: asset.localIdentifier,
            mediaType: mediaType
        )
    }

    /// Idle timeout for the rendered-asset request. If the PHImageManager
    /// request produces no progress for this long, the watchdog cancels it and
    /// throws — so a request whose completion handler never fires (network drop
    /// mid-iCloud-download) can't wedge the process-global `gate` forever.
    static let renderStallThreshold: TimeInterval = 30

    /// Export an edited asset by rendering its current version through
    /// PHImageManager. Used when the `.fullSizePhoto` resource is missing, so
    /// the edit exists only as adjustment data.
    private func importRenderedAsset(
        _ asset: PHAsset,
        originalFilename: String,
        to directory: URL
    ) async throws -> ImportedAsset {
        // Same assetsd budget concern as writeResource — serialize the request.
        await Self.gate.wait()
        defer {
            Task.detached { await Self.gate.signal() }
        }

        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        let state = RenderState()
        // Downloads report progress; each callback resets the idle timer.
        options.progressHandler = { _, _, _, _ in state.noteActivity() }

        let (data, dataUTI): (Data, String?) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, String?), Error>) in
                let requestID = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, info in
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    guard state.claimResume() else { return }
                    state.cancelWatchdog()
                    if let data {
                        continuation.resume(returning: (data, uti))
                    } else if let error = info?[PHImageErrorKey] as? Error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: PhotosImportError.exportFailed)
                    }
                }
                // Arm the watchdog; it stays as the backstop even across task
                // cancellation, so the continuation always resumes eventually.
                state.arm(requestID: requestID, stallThreshold: Self.renderStallThreshold) {
                    PHImageManager.default().cancelImageRequest(requestID)
                    if state.claimResume() {
                        continuation.resume(throwing: PhotosImportError.stalled)
                    }
                }
            }
        } onCancel: {
            // Hasten completion; if the handler never fires, the still-armed
            // watchdog will resume-throw within the idle threshold.
            if let id = state.requestID {
                PHImageManager.default().cancelImageRequest(id)
            }
        }

        // The render's format can differ from the original (e.g. HEIC original,
        // JPEG render) — keep the original stem but correct the extension.
        var filename = originalFilename
        if let dataUTI, let ext = UTType(dataUTI)?.preferredFilenameExtension {
            filename = (originalFilename as NSString).deletingPathExtension + "." + ext
        }
        let finalURL = uniqueURL(for: directory.appendingPathComponent(filename))
        try data.write(to: finalURL, options: .atomic)

        return ImportedAsset(
            fileURL: finalURL,
            originalFilename: filename,
            creationDate: asset.creationDate,
            phAssetLocalIdentifier: asset.localIdentifier
        )
    }

    /// Export an edited video by rendering its current version through a
    /// PHImageManager export session. Used when the `.fullSizeVideo` resource is
    /// missing — a cross-device edit that iCloud hasn't materialized, or a
    /// slow-mo whose current version exists only as an AVComposition.
    ///
    /// Tries `AVAssetExportPresetPassthrough` first (no re-encode); compositions
    /// that passthrough can't handle fall back to
    /// `AVAssetExportPresetHighestQuality`. Output is always a QuickTime
    /// container, so the original stem gets a `.mov` extension.
    private func importRenderedVideo(
        _ asset: PHAsset,
        originalFilename: String,
        to directory: URL
    ) async throws -> ImportedAsset {
        // Same assetsd budget concern as writeResource — serialize the request.
        await Self.gate.wait()
        defer {
            Task.detached { await Self.gate.signal() }
        }

        let filename = (originalFilename as NSString).deletingPathExtension + ".mov"
        let finalURL = uniqueURL(for: directory.appendingPathComponent(filename))

        do {
            let session = try await requestVideoExportSession(
                for: asset, preset: AVAssetExportPresetPassthrough
            )
            try await session.export(to: finalURL, as: .mov)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Passthrough is incompatible with some compositions (slow-mo).
            // Re-request with a re-encoding preset and try once more.
            try? FileManager.default.removeItem(at: finalURL)
            let session = try await requestVideoExportSession(
                for: asset, preset: AVAssetExportPresetHighestQuality
            )
            try await session.export(to: finalURL, as: .mov)
        }

        return ImportedAsset(
            fileURL: finalURL,
            originalFilename: filename,
            creationDate: asset.creationDate,
            phAssetLocalIdentifier: asset.localIdentifier,
            mediaType: .video
        )
    }

    /// Carries the non-Sendable `AVAssetExportSession` out of the PHImageManager
    /// result handler. Safe: the handler never touches the session after
    /// resuming the continuation, so ownership genuinely transfers.
    private struct ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
    }

    /// Obtain an export session for the asset's current version, with the same
    /// idle watchdog as the photo render path — the iCloud download behind
    /// `requestExportSession` can stall, and its completion handler is not
    /// guaranteed to fire after a network drop.
    private func requestVideoExportSession(
        for asset: PHAsset,
        preset: String
    ) async throws -> AVAssetExportSession {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        let state = RenderState()
        // Downloads report progress; each callback resets the idle timer.
        options.progressHandler = { _, _, _, _ in state.noteActivity() }

        let box = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExportSessionBox, Error>) in
                let requestID = PHImageManager.default().requestExportSession(
                    forVideo: asset,
                    options: options,
                    exportPreset: preset
                ) { session, info in
                    guard state.claimResume() else { return }
                    state.cancelWatchdog()
                    if let session {
                        continuation.resume(returning: ExportSessionBox(session: session))
                    } else if let error = info?[PHImageErrorKey] as? Error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: PhotosImportError.exportFailed)
                    }
                }
                state.arm(requestID: requestID, stallThreshold: Self.renderStallThreshold) {
                    PHImageManager.default().cancelImageRequest(requestID)
                    if state.claimResume() {
                        continuation.resume(throwing: PhotosImportError.stalled)
                    }
                }
            }
        } onCancel: {
            // Hasten completion; if the handler never fires, the still-armed
            // watchdog will resume-throw within the idle threshold.
            if let id = state.requestID {
                PHImageManager.default().cancelImageRequest(id)
            }
        }
        return box.session
    }

    // MARK: - writeResource with retry + cancellable + exponential watchdog

    static let maxStallAttempts = 10
    /// Suppress the user-facing "downloading from iCloud" message until the
    /// asset has been struggling for at least this long. Without this, a brief
    /// stall on attempt 0 that resolves on attempt 1 produces a sub-second
    /// flicker of the message.
    static let slowMessageDelay: TimeInterval = 5
    /// Once the slow message is shown, keep it visible for at least this long
    /// even if the underlying stall resolves immediately. Prevents the message
    /// from appearing and disappearing within the same animation frame.
    static let slowMessageMinDisplay: TimeInterval = 2

    private func writeResourceWithRetry(
        _ resource: PHAssetResource,
        to url: URL,
        filename: String,
        callbacks: PhotosImportCallbacks
    ) async throws {
        var lastError: Error?
        let assetStart = Date()

        for attempt in 0..<Self.maxStallAttempts {
            try Task.checkCancellation()

            if attempt > 0 {
                // Clean any partial file from the previous attempt
                try? FileManager.default.removeItem(at: url)
            }

            do {
                try await writeResource(
                    resource,
                    to: url,
                    filename: filename,
                    attempt: attempt,
                    assetStart: assetStart,
                    callbacks: callbacks
                )
                callbacks.health(.normal)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch PhotosImportError.stalled {
                // The watchdog tripped — doubled threshold applies on the next attempt.
                lastError = PhotosImportError.stalled
                continue
            } catch let error as PhotosImportError {
                throw error
            } catch {
                lastError = error
                if !Self.isTransientPhotosError(error) {
                    // Non-transient — don't waste retries
                    throw error
                }
                // Transient framework error — brief pause before next attempt
                try await Task.sleep(for: .milliseconds(500))
            }
        }

        if let err = lastError as? PhotosImportError, err == .stalled {
            throw PhotosImportError.exportTimedOut
        }
        throw lastError ?? PhotosImportError.exportFailed
    }

    /// Single attempt to stream the resource bytes into `url`. Uses the
    /// cancellable `requestData` API so Task cancellation propagates to
    /// assetsd via `cancelDataRequest(_:)` rather than leaving an orphan
    /// request behind.
    private func writeResource(
        _ resource: PHAssetResource,
        to url: URL,
        filename: String,
        attempt: Int,
        assetStart: Date,
        callbacks: PhotosImportCallbacks
    ) async throws {
        // Serialize every resource request to protect assetsd's per-client budget.
        await Self.gate.wait()

        // `signal()` must happen regardless of success/failure/cancel.
        // AsyncSemaphore is an actor, so release via a detached Task so the
        // defer remains synchronous from the caller's perspective.
        defer {
            Task.detached { await Self.gate.signal() }
        }

        // Create the destination file up-front so FileHandle can write chunks.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw PhotosImportError.exportFailed
        }

        let state = WriteState(filename: filename)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let opts = PHAssetResourceRequestOptions()
                opts.isNetworkAccessAllowed = true

                let id = PHAssetResourceManager.default().requestData(
                    for: resource,
                    options: opts,
                    dataReceivedHandler: { chunk in
                        state.noteChunk()
                        try? handle.write(contentsOf: chunk)
                    },
                    completionHandler: { error in
                        try? handle.close()
                        state.completeRequest()
                        if state.claimResume() {
                            if let error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume()
                            }
                        }
                    }
                )
                state.setRequestID(id)

                // Watchdog: observe chunk activity. When the stream goes idle
                // longer than the per-attempt threshold (1, 2, 4, 8 … seconds,
                // doubling each retry), cancel the request and surface a stall
                // so the outer retry loop restarts with a fresh requestData.
                let stallThreshold = TimeInterval(1 << attempt)
                let maxAttempts = Self.maxStallAttempts
                let slowMessageDelay = Self.slowMessageDelay
                let watchdog = Task.detached { [state, callbacks] in
                    let tickInterval: TimeInterval = 0.5

                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(tickInterval))
                        if state.isComplete { break }

                        let idleFor = Date().timeIntervalSince(state.lastActivity)

                        if idleFor >= stallThreshold {
                            if let rid = state.requestID {
                                PHAssetResourceManager.default().cancelDataRequest(rid)
                            }
                            try? handle.close()
                            if state.claimResume() {
                                continuation.resume(throwing: PhotosImportError.stalled)
                            }
                            break
                        } else if idleFor > stallThreshold / 2 {
                            // Only surface the iCloud-download message after the
                            // asset has been struggling long enough to matter.
                            // Skips the sub-second flicker when attempt 1 succeeds
                            // immediately after a brief attempt 0 stall.
                            let elapsed = Date().timeIntervalSince(assetStart)
                            guard elapsed >= slowMessageDelay else { continue }
                            let secondsUntilRetry = max(0, Int(ceil(stallThreshold - idleFor)))
                            callbacks.health(.slow(.photosDownload(
                                filename: state.filename,
                                attempt: attempt,
                                maxAttempts: maxAttempts,
                                secondsUntilRetry: secondsUntilRetry
                            )))
                        } else {
                            callbacks.health(.normal)
                        }
                    }
                }
                state.setWatchdog(watchdog)
            }
        } onCancel: {
            // Runs on the cancelling thread. Tell assetsd to abandon its work
            // rather than letting the request orphan.
            state.cancelWatchdog()
            if let rid = state.requestID {
                PHAssetResourceManager.default().cancelDataRequest(rid)
            }
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func uniqueURL(for url: URL) -> URL {
        var candidate = url
        var counter = 1
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = "\(stem)_\(counter).\(ext)"
            candidate = url.deletingLastPathComponent().appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }

    /// Stream-based import that yields each asset as soon as it's copied to the staging directory.
    /// The returned stream produces results concurrently with consumption.
    /// Failed assets are yielded as `.failure`; per-asset timeouts and post-retry
    /// transient failures are yielded as `.skipped` so the UI can distinguish
    /// recoverable soft failures from real errors.
    func importAlbumStreaming(
        albumId: String,
        to importDirectory: URL,
        callbacks: PhotosImportCallbacks = PhotosImportCallbacks(),
        includeVideos: Bool = true,
        progress: @Sendable @escaping (Int, Int) -> Void
    ) async throws -> AsyncStream<ImportResult> {
        let fetchResult = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumId], options: nil
        )
        guard let collection = fetchResult.firstObject else {
            throw PhotosImportError.albumNotFound
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        fetchOptions.predicate = Self.mediaPredicate(includeVideos: includeVideos)
        let assets = PHAsset.fetchAssets(in: collection, options: fetchOptions)

        // Snapshot asset references so the stream closure can capture them
        var assetRefs: [PHAsset] = []
        assetRefs.reserveCapacity(assets.count)
        for i in 0..<assets.count { assetRefs.append(assets.object(at: i)) }

        return try importAssetsStreaming(
            assets: assetRefs,
            to: importDirectory,
            callbacks: callbacks,
            progress: progress
        )
    }

    /// Same as `importAlbumStreaming`, but takes an explicit list of `PHAsset`s
    /// instead of resolving them from an album. Used by re-sync flows where the
    /// caller has already computed the precise delta.
    func importAssetsStreaming(
        assets assetRefs: [PHAsset],
        to importDirectory: URL,
        callbacks: PhotosImportCallbacks = PhotosImportCallbacks(),
        progress: @Sendable @escaping (Int, Int) -> Void
    ) throws -> AsyncStream<ImportResult> {
        let total = assetRefs.count
        try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)

        // Gate the health callback so a .slow message stays visible for at
        // least `slowMessageMinDisplay` seconds. The gate persists for the
        // duration of the import, so it spans all assets in the album.
        let gate = HealthGate(
            minDisplay: Self.slowMessageMinDisplay,
            upstream: callbacks.health
        )
        let gatedCallbacks = PhotosImportCallbacks(health: { @Sendable health in
            gate.report(health)
        })

        let (stream, continuation) = AsyncStream.makeStream(of: ImportResult.self)

        let importDir = importDirectory
        let producerTask = Task {
            // Circuit breaker: reserved for the case where assetsd is genuinely
            // wedged (persistent XPC 46104). Slowness or single-asset failures
            // do NOT trip it.
            var consecutiveXPCFailures = 0
            let circuitBreakerThreshold = 5

            for (index, asset) in assetRefs.enumerated() {
                guard !Task.isCancelled else { break }
                do {
                    let result = try await self.importAsset(
                        asset,
                        to: importDir,
                        callbacks: gatedCallbacks
                    )
                    consecutiveXPCFailures = 0
                    continuation.yield(.success(result))
                } catch is CancellationError {
                    break
                } catch PhotosImportError.exportTimedOut {
                    // Soft: this one asset is wedged at the iCloud layer.
                    // Skip it and move on — not a user-facing error.
                    let filename = asset.value(forKey: "filename") as? String ?? "asset \(index)"
                    continuation.yield(.skipped(
                        assetIndex: index,
                        filename: filename,
                        reason: "iCloud download unavailable"
                    ))
                } catch {
                    if Self.isXPCServiceError(error) {
                        consecutiveXPCFailures += 1
                        if consecutiveXPCFailures >= circuitBreakerThreshold {
                            // Hard terminate: daemon is genuinely broken. Emit one
                            // clear, actionable error and stop hammering assetsd.
                            continuation.yield(.failure(
                                assetIndex: index,
                                error: "Photos services unavailable — quit Photos.app, wait 30 seconds, and retry the import."
                            ))
                            break
                        }
                        let filename = asset.value(forKey: "filename") as? String ?? "asset \(index)"
                        continuation.yield(.skipped(
                            assetIndex: index,
                            filename: filename,
                            reason: "Photos service temporarily unavailable"
                        ))
                    } else {
                        consecutiveXPCFailures = 0
                        continuation.yield(.failure(
                            assetIndex: index,
                            error: error.localizedDescription
                        ))
                    }
                }
                progress(index + 1, total)
            }
            gatedCallbacks.health(.normal)
            continuation.finish()
        }

        // If the consumer drops the stream, stop the producer
        continuation.onTermination = { _ in producerTask.cancel() }

        return stream
    }

    // MARK: - Error classification

    /// A transient Photos/XPC error worth retrying. Covers assetsd XPC
    /// availability blips, account daemon hiccups, and the opaque Cocoa -1
    /// that the Photos framework uses to surface downstream failures.
    nonisolated static func isTransientPhotosError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "com.apple.photos.error" { return true }
        if ns.domain == "com.apple.accounts" { return true }
        if ns.domain == NSCocoaErrorDomain && ns.code == -1 { return true }
        return false
    }

    /// Narrower: specifically the XPC/availability signal from assetsd.
    /// This is what trips the circuit breaker when it repeats.
    nonisolated static func isXPCServiceError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "com.apple.photos.error" && ns.code == 46104 { return true }
        if ns.domain == "com.apple.accounts" { return true }
        return false
    }

    // MARK: - Errors

    enum PhotosImportError: Error, Equatable {
        case albumNotFound
        case noResourceFound
        case exportFailed
        case exportTimedOut
        case stalled
    }
}

// MARK: - WriteState

/// Per-request state shared between the watchdog, data handler, completion
/// handler, and cancellation path. All access is thread-safe via an unfair
/// lock; the class is nonisolated so it can be touched from the PHAssetResourceManager
/// callback threads as well as the detached watchdog task.
nonisolated private final class WriteState: @unchecked Sendable {
    let filename: String
    private let lock = OSAllocatedUnfairLock<Storage>(initialState: Storage())

    private struct Storage {
        var lastActivity: Date = .init()
        var requestID: PHAssetResourceDataRequestID?
        var watchdog: Task<Void, Never>?
        var complete: Bool = false
        var resumed: Bool = false
    }

    init(filename: String) {
        self.filename = filename
    }

    var lastActivity: Date { lock.withLock { $0.lastActivity } }
    var requestID: PHAssetResourceDataRequestID? { lock.withLock { $0.requestID } }
    var isComplete: Bool { lock.withLock { $0.complete } }

    func noteChunk() {
        lock.withLock { $0.lastActivity = .init() }
    }

    func setRequestID(_ id: PHAssetResourceDataRequestID) {
        lock.withLock { $0.requestID = id }
    }

    func setWatchdog(_ task: Task<Void, Never>) {
        lock.withLock { $0.watchdog = task }
    }

    func cancelWatchdog() {
        let task = lock.withLock { state -> Task<Void, Never>? in
            let t = state.watchdog
            state.watchdog = nil
            return t
        }
        task?.cancel()
    }

    func completeRequest() {
        let task = lock.withLock { state -> Task<Void, Never>? in
            state.complete = true
            let t = state.watchdog
            state.watchdog = nil
            return t
        }
        task?.cancel()
    }

    /// Returns true if this caller wins the race to resume the continuation.
    /// The continuation must resume exactly once.
    func claimResume() -> Bool {
        lock.withLock { state in
            guard !state.resumed else { return false }
            state.resumed = true
            return true
        }
    }
}

// MARK: - RenderState

/// State shared between the PHImageManager result handler, the idle watchdog,
/// and the task-cancellation path for a single `importRenderedAsset` request.
/// Thread-safe via an unfair lock; nonisolated so the framework callback threads
/// and the detached watchdog can all touch it.
nonisolated private final class RenderState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Storage>(initialState: Storage())

    private struct Storage {
        var lastActivity: Date = .init()
        var requestID: PHImageRequestID?
        var watchdog: Task<Void, Never>?
        var resumed: Bool = false
    }

    var requestID: PHImageRequestID? { lock.withLock { $0.requestID } }

    func noteActivity() {
        lock.withLock { $0.lastActivity = .init() }
    }

    /// Returns true for the single caller that wins the race to resume the
    /// continuation, which must resume exactly once.
    func claimResume() -> Bool {
        lock.withLock { state in
            guard !state.resumed else { return false }
            state.resumed = true
            return true
        }
    }

    func cancelWatchdog() {
        let task = lock.withLock { state -> Task<Void, Never>? in
            let t = state.watchdog
            state.watchdog = nil
            return t
        }
        task?.cancel()
    }

    /// Start the idle watchdog. `onStall` fires when the request produces no
    /// activity for `stallThreshold` seconds.
    func arm(requestID: PHImageRequestID, stallThreshold: TimeInterval, onStall: @escaping @Sendable () -> Void) {
        lock.withLock { $0.requestID = requestID }
        let watchdog = Task.detached { [weak self] in
            let tick: TimeInterval = 0.5
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(tick))
                guard let self else { return }
                let idle = Date().timeIntervalSince(self.lock.withLock { $0.lastActivity })
                if idle >= stallThreshold {
                    onStall()
                    return
                }
            }
        }
        lock.withLock { $0.watchdog = watchdog }
    }
}

// MARK: - HealthGate

/// Wraps a `PipelineHealth` callback so a `.slow` event remains visible to the
/// user for at least `minDisplay` seconds. A `.normal` arriving inside that
/// window is deferred via a sleeping Task; a subsequent `.slow` cancels the
/// pending clear and resets the timer.
nonisolated private final class HealthGate: @unchecked Sendable {
    private let upstream: @Sendable (PipelineHealth) -> Void
    private let minDisplay: TimeInterval
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
        var lastSlowAt: Date?
        var pendingClear: Task<Void, Never>?
    }

    init(minDisplay: TimeInterval, upstream: @escaping @Sendable (PipelineHealth) -> Void) {
        self.minDisplay = minDisplay
        self.upstream = upstream
    }

    func report(_ health: PipelineHealth) {
        switch health {
        case .slow:
            let pending: Task<Void, Never>? = lock.withLock { state in
                let p = state.pendingClear
                state.pendingClear = nil
                state.lastSlowAt = Date()
                return p
            }
            pending?.cancel()
            upstream(health)

        case .normal:
            // Decide under the lock so a concurrent .slow can't slip between
            // the elapsed check and scheduling the deferred clear.
            let emitNow: Bool = lock.withLock { state in
                guard let lastSlow = state.lastSlowAt else {
                    return true
                }
                let elapsed = Date().timeIntervalSince(lastSlow)
                if elapsed >= minDisplay {
                    state.pendingClear?.cancel()
                    state.pendingClear = nil
                    state.lastSlowAt = nil
                    return true
                }
                if state.pendingClear != nil { return false }
                let delay = minDisplay - elapsed
                // Strong self: the sleeping Task keeps the gate alive long
                // enough to deliver the clear even if the producer task has
                // already exited. The cycle breaks when the closure releases.
                state.pendingClear = Task {
                    try? await Task.sleep(for: .seconds(delay))
                    if Task.isCancelled { return }
                    let shouldEmit: Bool = self.lock.withLock { state in
                        guard state.pendingClear != nil else { return false }
                        state.pendingClear = nil
                        state.lastSlowAt = nil
                        return true
                    }
                    if shouldEmit { self.upstream(.normal) }
                }
                return false
            }
            if emitNow { upstream(.normal) }
        }
    }
}
