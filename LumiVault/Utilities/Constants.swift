import Foundation
import SwiftUI

enum Constants {
    // MARK: - Design
    enum Design {
        static let accentColor = Color(.displayP3, red: 1.0, green: 0.439, blue: 0.0)

        static let monoLargeTitle = Font.system(.largeTitle, design: .monospaced).weight(.medium)
        static let monoTitle = Font.system(.title, design: .monospaced).weight(.medium)
        static let monoTitle2 = Font.system(.title2, design: .monospaced).weight(.medium)
        static let monoTitle3 = Font.system(.title3, design: .monospaced).weight(.medium)
        static let monoHeadline = Font.system(.headline, design: .monospaced)
        static let monoSubheadline = Font.system(.subheadline, design: .monospaced)
        static let monoBody = Font.system(.body, design: .monospaced)
        static let monoCaption = Font.system(.caption, design: .monospaced)
        static let monoCaption2 = Font.system(.caption2, design: .monospaced)
    }

    // MARK: - Paths
    enum Paths {
        nonisolated static let iCloudContainer = "iCloud.app.lumivault"

        /// The user-accessible archive folder, `~/Pictures/LumiVault`. Reachable directly
        /// (no security-scoped bookmark) thanks to the `assets.pictures.read-write` entitlement.
        /// This is the default home for both imported photos and `catalog.json` — see
        /// `resolvedCatalogURL`.
        ///
        /// Under the sandbox, `.picturesDirectory` returns the container-scoped path
        /// (`~/Library/Containers/…/Data/Pictures`), which is a symlink to the real
        /// `~/Pictures`. Resolve it so the app stores, displays, and reveals the real
        /// user-visible location — surfacing a container path in the UI is precisely
        /// what App Review rejected under guideline 2.4.5(i).
        nonisolated static var libraryURL: URL {
            let base = (try? FileManager.default.url(
                for: .picturesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            )) ?? URL(fileURLWithPath: ("~/Pictures" as NSString).expandingTildeInPath)
            return base.resolvingSymlinksInPath()
                .appendingPathComponent("LumiVault", isDirectory: true)
        }

        /// The legacy catalog location inside the sandbox container (`~/.lumivault/catalog.json`).
        /// Kept only so launch-time migration can move an existing catalog into `libraryURL`.
        nonisolated static var legacyContainerCatalogURL: URL {
            URL(fileURLWithPath: ("~/.lumivault/catalog.json" as NSString).expandingTildeInPath)
        }

        /// Resolves the catalog file URL — the user-configured override if set, otherwise
        /// `~/Pictures/LumiVault/catalog.json`. Safe to call from any isolation context.
        nonisolated static var resolvedCatalogURL: URL {
            if let raw = UserDefaults.standard.string(forKey: "catalogPath") {
                return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            }
            return libraryURL.appendingPathComponent("catalog.json")
        }
    }

    // MARK: - Storage
    enum Storage {
        /// Reserved `StorageLocation.volumeID` for the local library folder. Real volumes use
        /// UUID strings (`VolumeRecord.volumeID`), so this fixed sentinel never collides. Resolved
        /// to `Paths.libraryURL` by `StorageResolver`.
        nonisolated static let libraryVolumeID = "local-library"
        nonisolated static let libraryLabel = "Library"
    }

    // MARK: - Thumbnails
    enum Thumbnails {
        static let gridSize = 256
        static let listSize = 64
        static let heicQuality: Float = 0.65
        static let memoryCacheLimit = 128 * 1024 * 1024 // 128 MB
        static let diskCacheLimit: Int64 = 2 * 1024 * 1024 * 1024 // 2 GB
    }

    // MARK: - Deduplication
    enum Dedup {
        static let nearDuplicateThreshold = 5 // Hamming distance
    }

    // MARK: - Media
    enum Media {
        /// CryptoKit's AES-GCM is one-shot: plaintext and ciphertext are both held in
        /// memory (~2x file size). Files above this limit are stored unencrypted with a
        /// surfaced warning instead of risking memory exhaustion mid-import.
        nonisolated static let encryptionSizeLimit: Int64 = 2 * 1024 * 1024 * 1024 // 2 GB

        /// B2 recommends the large-file API above 200 MB (hard single-call limit is 5 GB).
        nonisolated static let b2LargeFileThreshold: Int64 = 200 * 1024 * 1024
        /// Part size for B2 large-file uploads (minimum allowed is 5 MB).
        nonisolated static let b2PartSize: Int64 = 100 * 1024 * 1024

        /// Ceiling on the total bytes of concurrent memory-heavy import work
        /// (encryption + GPU PAR2). The encryption and PAR2 stages each load a
        /// whole file into memory; without a shared budget, several large videos
        /// in flight stack into multi-GB peaks that wedge the import. Photos are
        /// tiny and flow freely under this budget; only large videos serialize.
        nonisolated static let importMemoryBudget: Int64 = 1_500 * 1024 * 1024 // ~1.5 GB
        /// Peak resident multiple of file size while AES-GCM sealing one-shot
        /// (plaintext + sealed box + combined output held at once).
        nonisolated static let encryptionMemoryFactor: Int64 = 3
        /// Peak resident multiple while generating PAR2 (CPU `Data` plus the
        /// Metal buffer in unified memory).
        nonisolated static let par2MemoryFactor: Int64 = 2
    }
}
