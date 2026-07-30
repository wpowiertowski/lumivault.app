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

        /// Launch-environment key that redirects the whole library — photos, catalog,
        /// sidecars — into a throwaway directory.
        ///
        /// UI tests drive the real app binary, which otherwise reads and *writes*
        /// the user's `~/Pictures/LumiVault`: importing during a UI test would file
        /// junk albums into a real archive and rewrite its catalog.json. Reading it
        /// from the process environment (rather than a settable global) means only a
        /// process launched with it is affected, and nothing in the shipping app can
        /// set it on itself.
        nonisolated static let uiTestLibraryEnvKey = "LUMIVAULT_UITEST_LIBRARY"

        /// Non-nil only when the process was launched for UI testing.
        nonisolated static var uiTestLibraryOverride: URL? {
            guard let raw = ProcessInfo.processInfo.environment[uiTestLibraryEnvKey],
                  !raw.isEmpty else { return nil }
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }

        // MARK: Sandbox isolation
        //
        // Production paths used to be the default and isolation something each test had
        // to remember. That cost the real archive three times: an import with no target
        // volume falls back to `libraryURL`, every import test rewrote the real
        // catalog.json, and a store rebuild lost every VolumeRecord. Each was patched
        // individually; this reverses the default instead.

        /// True when this process is a test runner rather than the app.
        ///
        /// Two signals, because the runners differ and neither covers both:
        ///
        /// - `xcodebuild test` hosts the tests *inside* the app, so `Bundle.main` is the
        ///   app and carries its identifier; XCTest sets `XCTestConfigurationFilePath`.
        /// - `swift test` runs them in `swiftpm-testing-helper`, which has no bundle
        ///   identifier at all and sets no such variable.
        ///
        /// Measured, not assumed. Under `swift test` on this repo, `XCTest` and
        /// `XCTestCase` are both absent from the ObjC runtime, `Bundle.allBundles` holds
        /// no `.xctest`, and `XCTestConfigurationFilePath` is unset — `otool -L` shows the
        /// test binary links only `Testing.framework`, because SwiftPM does not link
        /// XCTest into a Swift Testing bundle. Detecting the *test framework* therefore
        /// cannot work here; detecting the absence of an *app identity* does.
        ///
        /// Anything unrecognised reads as a test and lands in a sandbox, so the failure
        /// direction is a redirected developer rather than a clobbered archive.
        nonisolated static var isTestProcess: Bool {
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || Bundle.main.bundleIdentifier == nil
        }

        /// Whether this process may resolve the real `~/Pictures/LumiVault`.
        nonisolated static var resolvesProductionLibrary: Bool {
            uiTestLibraryOverride == nil && !isTestProcess
        }

        /// Per-process sandbox root, stable for the process lifetime.
        ///
        /// A `static let` so every accessor in one run agrees on the directory; the pid
        /// and UUID keep concurrent runs (SwiftPM and xcodebuild in the same CI job)
        /// apart. Created here so a redirected `applicationSupportURL` exists before
        /// SwiftData tries to open a store inside it.
        nonisolated static let sandboxRootURL: URL = {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "LumiVault-Sandbox-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true
            )
            for sub in ["Library", "Application Support"] {
                try? FileManager.default.createDirectory(
                    at: root.appendingPathComponent(sub, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            return root
        }()

        /// Where a redirected process keeps its library, or `nil` in production.
        ///
        /// `#if DEBUG` is belt-and-braces, not the mechanism: the test bundle and a
        /// developer's Debug app are both Debug and need opposite answers, which is why
        /// `isTestProcess` does the real work. But a Release binary that never compiles
        /// this branch cannot redirect a user's archive on a false positive, and that is
        /// worth the two lines. (A `swift test -c release` run would therefore reach
        /// production — `RealLibraryGuardTests` asserts against that rather than trusting
        /// it not to happen.)
        nonisolated static var sandboxLibraryURL: URL? {
            #if DEBUG
            guard uiTestLibraryOverride == nil, isTestProcess else { return nil }
            return sandboxRootURL.appendingPathComponent("Library", isDirectory: true)
            #else
            return nil
            #endif
        }

        /// The real archive folder, `~/Pictures/LumiVault`, with no redirect applied.
        ///
        /// Split out from `libraryURL` so the production resolution stays assertable from
        /// a test process that is itself redirected — and so guards that must inspect the
        /// *user's* archive (`RealLibraryGuardTests`) cannot be quietly pointed at a
        /// sandbox and keep passing.
        ///
        /// Under the sandbox, `.picturesDirectory` returns the container-scoped path
        /// (`~/Library/Containers/…/Data/Pictures`), which is a symlink to the real
        /// `~/Pictures`. Resolve it so the app stores, displays, and reveals the real
        /// user-visible location — surfacing a container path in the UI is precisely
        /// what App Review rejected under guideline 2.4.5(i).
        nonisolated static var productionLibraryURL: URL {
            let base = (try? FileManager.default.url(
                for: .picturesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            )) ?? URL(fileURLWithPath: ("~/Pictures" as NSString).expandingTildeInPath)
            return base.resolvingSymlinksInPath()
                .appendingPathComponent("LumiVault", isDirectory: true)
        }

        /// The archive folder this process should use. Reachable directly (no
        /// security-scoped bookmark) thanks to the `assets.pictures.read-write`
        /// entitlement. Default home for both imported photos and `catalog.json` — see
        /// `resolvedCatalogURL`.
        nonisolated static var libraryURL: URL {
            if let override = uiTestLibraryOverride { return override }
            if let sandbox = sandboxLibraryURL { return sandbox }
            return productionLibraryURL
        }

        /// Application Support for this process, redirected under test.
        ///
        /// `SwiftDataContainer` and `ThumbnailService` both used
        /// `URL.applicationSupportDirectory` directly. That was isolated only by accident
        /// — an unsandboxed test process resolves it outside the app's container — and
        /// not at all for UI tests, where the app *is* sandboxed and a UI-driven import
        /// wrote thumbnails into the developer's real cache.
        nonisolated static var applicationSupportURL: URL {
            if let override = uiTestLibraryOverride {
                let dir = override.appendingPathComponent("Application Support", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir
            }
            if sandboxLibraryURL != nil {
                return sandboxRootURL.appendingPathComponent("Application Support", isDirectory: true)
            }
            return URL.applicationSupportDirectory
        }

        /// The legacy catalog location inside the sandbox container (`~/.lumivault/catalog.json`).
        /// Kept only so launch-time migration can move an existing catalog into `libraryURL`.
        nonisolated static var legacyContainerCatalogURL: URL {
            URL(fileURLWithPath: ("~/.lumivault/catalog.json" as NSString).expandingTildeInPath)
        }

        /// UserDefaults key for the user-configured catalog location.
        nonisolated static let catalogPathDefaultsKey = "catalogPath"

        /// Resolves the catalog file URL — the user-configured override if set, otherwise
        /// `~/Pictures/LumiVault/catalog.json`. Safe to call from any isolation context.
        ///
        /// The UI-test library override wins over the user's `catalogPath` default, and
        /// has to: a developer who has pointed `catalogPath` at their real archive would
        /// otherwise have it rewritten by a UI-driven import even with the library
        /// redirected, which is the exact hazard the override exists to prevent.
        /// `UserDefaults` is process-wide and is not isolated for UI tests.
        nonisolated static var resolvedCatalogURL: URL {
            resolveCatalogURL(
                override: UserDefaults.standard.string(forKey: catalogPathDefaultsKey),
                uiTestLibrary: uiTestLibraryOverride,
                sandboxLibrary: sandboxLibraryURL
            )
        }

        /// The resolution itself, with both inputs passed in. Split out so tests
        /// can exercise it without writing to `UserDefaults.standard` or the process
        /// environment — both process-wide globals that every concurrently running
        /// test shares.
        nonisolated static func resolveCatalogURL(
            override raw: String?, uiTestLibrary: URL? = nil, sandboxLibrary: URL? = nil
        ) -> URL {
            // Both redirects outrank the user's `catalogPath`, and have to. Redirecting
            // `libraryURL` alone does *not* close this path: the override is consulted
            // first, so a developer who has pointed `catalogPath` at their real archive
            // keeps writing to it no matter where the library resolves. That is the
            // hazard the UI-test override was added for, and it is why the sandbox needs
            // the same precedence position rather than relying on derivation from
            // `libraryURL` further down.
            if let uiTestLibrary {
                return uiTestLibrary.appendingPathComponent("catalog.json")
            }
            if let sandboxLibrary {
                return sandboxLibrary.appendingPathComponent("catalog.json")
            }
            if let raw {
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
