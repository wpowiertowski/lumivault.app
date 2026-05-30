import Foundation

/// Validation for path components sourced from `catalog.json`.
///
/// `catalog.json` is an untrusted artifact — it can be restored from a Backblaze B2
/// bucket, an arbitrary user-selected file, or merged from an iCloud-synced copy.
/// Its `filename`, `par2_filename`, and album `year`/`month`/`day`/name fields are
/// later joined into filesystem paths (export, volume sync, deletion, reconciliation).
/// A component containing `..` or a path separator would let a tampered catalog escape
/// the intended album directory and read, overwrite, or delete files elsewhere within
/// the app's security-scoped roots. Reject such components at ingestion.
enum PathComponentValidation {
    /// A catalog-derived path component is safe iff it is a single, non-traversing name.
    nonisolated static func isSafe(_ component: String) -> Bool {
        guard !component.isEmpty, component != ".", component != ".." else { return false }
        guard !component.contains("/"), !component.contains("\\") else { return false }
        guard !component.contains("\0") else { return false }
        guard !component.hasPrefix("/") else { return false }
        // Catch-all: anything that isn't its own last path component is multi-segment
        // or otherwise abnormal (e.g. a trailing slash).
        return component == (component as NSString).lastPathComponent
    }

    /// Validate the four album-level keys plus an image filename and (optional) PAR2 name.
    /// `par2Filename` is allowed to be empty (it's optional per-image); when present it
    /// must also be a safe single component.
    nonisolated static func isSafeImage(
        year: String, month: String, day: String, albumName: String,
        filename: String, par2Filename: String
    ) -> Bool {
        isSafeAlbum(year: year, month: month, day: day, albumName: albumName)
            && isSafe(filename)
            && (par2Filename.isEmpty || isSafe(par2Filename))
    }

    /// Validate the four album-level path keys.
    nonisolated static func isSafeAlbum(year: String, month: String, day: String, albumName: String) -> Bool {
        isSafe(year) && isSafe(month) && isSafe(day) && isSafe(albumName)
    }
}

extension URL {
    /// True if this URL is `root` itself or a descendant of it, after standardizing both
    /// (which resolves any `..`/`.` segments). Use as a defensive guard before writing to
    /// or deleting a path built from externally-sourced components.
    nonisolated func isDescendant(of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let selfPath = standardizedFileURL.path
        return selfPath == rootPath || selfPath.hasPrefix(rootPath + "/")
    }
}
