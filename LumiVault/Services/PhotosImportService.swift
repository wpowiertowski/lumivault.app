import Foundation
import Photos
import os

struct PhotosAlbum: Identifiable, Sendable {
    let id: String
    let title: String
    let assetCount: Int
    let startDate: Date?
    let endDate: Date?
}

struct ImportedAsset: Sendable {
    let fileURL: URL
    let originalFilename: String
    let creationDate: Date?
    let phAssetLocalIdentifier: String?

    nonisolated init(fileURL: URL, originalFilename: String, creationDate: Date?, phAssetLocalIdentifier: String? = nil) {
        self.fileURL = fileURL
        self.originalFilename = originalFilename
        self.creationDate = creationDate
        self.phAssetLocalIdentifier = phAssetLocalIdentifier
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

    // MARK: - Album Enumeration

    func fetchAlbums() -> [PhotosAlbum] {
        var albums: [PhotosAlbum] = []

        // Only count images — import filters to images, so counts must match
        let imageOnly = PHFetchOptions()
        imageOnly.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        // User-created albums
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil
        )
        userAlbums.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: imageOnly)
            albums.append(PhotosAlbum(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled",
                assetCount: assets.count,
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
            guard assets.count > 0 else { return }
            albums.append(PhotosAlbum(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled",
                assetCount: assets.count,
                startDate: collection.startDate,
                endDate: collection.endDate
            ))
        }

        return albums
    }

    // MARK: - Album Asset Diff

    /// Returns the current image PHAssets in the named album, or `nil` if the
    /// album is no longer present (e.g. the user deleted it in Photos).
    func fetchAssets(in albumLocalIdentifier: String) -> [PHAsset]? {
        let fetchResult = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumLocalIdentifier], options: nil
        )
        guard let collection = fetchResult.firstObject else { return nil }

        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(in: collection, options: opts)

        var refs: [PHAsset] = []
        refs.reserveCapacity(assets.count)
        for i in 0..<assets.count {
            refs.append(assets.object(at: i))
        }
        return refs
    }

    // MARK: - Single Asset Import

    private func importAsset(
        _ asset: PHAsset,
        to directory: URL,
        callbacks: PhotosImportCallbacks
    ) async throws -> ImportedAsset {
        let resources = PHAssetResource.assetResources(for: asset)

        // Prefer edited (fullSizePhoto) over unedited original (photo)
        // so that user edits from Photos are preserved in the import
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo })
                ?? resources.first else {
            throw PhotosImportError.noResourceFound
        }

        // Use the original resource's filename (fullSizePhoto always reports "FullSizeRender.jpeg")
        let originalResource = resources.first(where: { $0.type == .photo })
        let filename = originalResource?.originalFilename ?? resource.originalFilename
        let destURL = directory.appendingPathComponent(filename)

        // Handle filename collisions
        let finalURL = uniqueURL(for: destURL)

        try await writeResourceWithRetry(resource, to: finalURL, filename: filename, callbacks: callbacks)

        return ImportedAsset(
            fileURL: finalURL,
            originalFilename: filename,
            creationDate: asset.creationDate,
            phAssetLocalIdentifier: asset.localIdentifier
        )
    }

    // MARK: - writeResource with retry + cancellable + exponential watchdog

    static let maxStallAttempts = 10
    /// Suppress the user-facing "downloading from iCloud" message until the
    /// asset has been struggling for at least this long. Without this, a brief
    /// stall on attempt 0 that resolves on attempt 1 produces a sub-second
    /// flicker of the message.
    static let slowMessageDelay: TimeInterval = 5

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
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
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
                        callbacks: callbacks
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
            callbacks.health(.normal)
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
