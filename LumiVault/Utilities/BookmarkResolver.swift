import Foundation

enum BookmarkResolver {
    /// Create a security-scoped bookmark for the given URL.
    static func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: [.volumeNameKey, .volumeUUIDStringKey],
            relativeTo: nil
        )
    }

    /// Resolve a security-scoped bookmark, returning the URL and whether it's stale.
    static func resolve(_ bookmarkData: Data) throws -> (url: URL, isStale: Bool) {
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
    static func resolveAndAccess(_ bookmarkData: Data) throws -> URL {
        let (url, isStale) = try resolve(bookmarkData)

        if isStale {
            throw BookmarkError.staleBookmark
        }

        guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkError.accessDenied
        }

        return url
    }

    enum BookmarkError: Error {
        case staleBookmark
        case accessDenied
    }
}
