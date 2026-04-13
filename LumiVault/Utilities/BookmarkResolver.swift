import Foundation

enum BookmarkResolver {
    /// Create a security-scoped bookmark for the given URL.
    nonisolated static func createBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = .withSecurityScope
        #else
        let options: URL.BookmarkCreationOptions = .minimalBookmark
        #endif
        return try url.bookmarkData(
            options: options,
            includingResourceValuesForKeys: [.volumeNameKey, .volumeUUIDStringKey],
            relativeTo: nil
        )
    }

    /// Resolve a security-scoped bookmark, returning the URL and whether it's stale.
    nonisolated static func resolve(_ bookmarkData: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        #if os(macOS)
        let resolveOptions: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let resolveOptions: URL.BookmarkResolutionOptions = .withoutUI
        #endif
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: resolveOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    /// Resolve and start accessing a security-scoped resource.
    /// Remember to call `url.stopAccessingSecurityScopedResource()` when done.
    nonisolated static func resolveAndAccess(_ bookmarkData: Data) throws -> URL {
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
