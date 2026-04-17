import Foundation

enum BookmarkResolver {
    /// Create a security-scoped bookmark for the given URL.
    nonisolated static func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: [.volumeNameKey, .volumeUUIDStringKey],
            relativeTo: nil
        )
    }

    /// Resolve a security-scoped bookmark, returning the URL and whether it's stale.
    nonisolated static func resolve(_ bookmarkData: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    /// Resolve and start accessing a security-scoped resource.
    /// Remember to call `url.stopAccessingSecurityScopedResource()` when done.
    nonisolated static func resolveAndAccess(_ bookmarkData: Data) throws -> URL {
        let (url, _) = try resolve(bookmarkData)

        guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkError.accessDenied
        }

        return url
    }

    /// Resolve, start accessing, and refresh the bookmark if stale.
    /// Returns the accessed URL and refreshed bookmark data (nil if not stale).
    nonisolated static func resolveAccessAndRefresh(_ bookmarkData: Data) throws -> (url: URL, refreshedBookmark: Data?) {
        let (url, isStale) = try resolve(bookmarkData)

        guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkError.accessDenied
        }

        if isStale {
            let refreshed = try? createBookmark(for: url)
            return (url, refreshed)
        }

        return (url, nil)
    }

    enum BookmarkError: Error {
        case staleBookmark
        case accessDenied
    }
}
