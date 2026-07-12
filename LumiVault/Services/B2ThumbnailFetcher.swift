import Foundation

/// Downloads originals from B2 so thumbnails can be regenerated when no local copy
/// exists — e.g. a second Mac whose records were hydrated from the synced catalog.
///
/// A single shared instance reuses one authorized B2Service and bounds concurrent
/// downloads, so a grid full of missing thumbnails doesn't fire an unbounded number
/// of parallel requests while scrolling.
actor B2ThumbnailFetcher {
    static let shared = B2ThumbnailFetcher()

    private let b2 = B2Service()
    private let semaphore = AsyncSemaphore(count: 4)

    /// Fetch the original file bytes (ciphertext if the file was stored encrypted).
    /// Returns nil on any failure — callers leave the thumbnail pending and retry later.
    func fetchOriginal(fileId: String, credentials: B2Credentials) async -> Data? {
        await semaphore.wait()
        defer { Task { await semaphore.signal() } }
        return try? await b2.downloadFile(fileId: fileId, credentials: credentials)
    }
}
