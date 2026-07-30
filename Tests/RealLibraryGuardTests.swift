import Testing
import Foundation
@testable import LumiVault

// MARK: - Guard: no test may touch the real library
//
// This exists because two separate defects in this test suite wrote into the
// developer's actual `~/Pictures/LumiVault`:
//
//  1. A pipeline run with no reachable target volume falls back to
//     `Constants.Paths.libraryURL` as the copy destination, so photos landed in
//     the real archive.
//  2. `runImportPipeline` saved `catalog.json` to
//     `Constants.Paths.resolvedCatalogURL` regardless of the injected
//     `CatalogService` or the target volumes — so *every* import test replaced a
//     5,000-entry archive catalog with its own two-file one. Redirecting the
//     file copies to a temp volume did not prevent this; the catalog save is a
//     separate path and needed its own seam.
//
// Both were silent: the tests passed, and the damage was only visible by
// looking at the real library. A green suite is not evidence that a test did
// not scribble outside its sandbox, so assert it directly.

@Suite
@MainActor
struct RealLibraryGuardTests {

    /// Fails if the real catalog looks like it was overwritten by a test.
    ///
    /// The signature is unmistakable: an archive catalog holds thousands of
    /// entries across many albums, while a test catalog holds a handful under
    /// one album named for a fixture. This does not run *before* the suite, so
    /// it cannot prevent the damage — it makes a recurrence impossible to miss.
    @Test func theRealCatalogWasNotReplacedByATestCatalog() throws {
        // Explicitly the production path. This used to read
        // `resolveCatalogURL(override: nil)`, which now follows the sandbox redirect —
        // the guard would have inspected its own throwaway catalog and passed
        // unconditionally, which is a worse outcome than not having it.
        let url = Constants.Paths.productionLibraryURL.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let data = try Data(contentsOf: url)
        guard let catalog = try? JSONDecoder.catalogDecoder.decode(Catalog.self, from: data) else {
            return  // unreadable for unrelated reasons; not this guard's business
        }

        var albumNames: Set<String> = []
        var entries = 0
        for year in catalog.years.values {
            for month in year.months.values {
                for day in month.days.values {
                    for (name, album) in day.albums {
                        albumNames.insert(name)
                        entries += album.images.count
                    }
                }
            }
        }

        // Album names the fixtures use. Their presence in the *real* catalog can
        // only mean a test wrote there.
        let fixtureAlbums: Set<String> = ["Trip", "Beach", "Probe", "Alpha", "Zulu"]
        let leaked = albumNames.intersection(fixtureAlbums)

        // A real archive has many albums; a leaked test catalog has one or two.
        // Only flag when the catalog is *both* tiny and fixture-named, so a
        // developer whose genuine archive contains an album called "Trip" is not
        // told their data was clobbered.
        let looksLikeATestCatalog = !leaked.isEmpty && albumNames.count <= 3 && entries < 25
        #expect(
            !looksLikeATestCatalog,
            """
            The real catalog at \(url.path) appears to have been overwritten by a test \
            (\(entries) entries across \(albumNames.sorted())). A test wrote outside its \
            sandbox — check that every PipelinedImportCoordinator built in a test passes \
            its own `catalogURL`, and that no import runs without a reachable target volume.
            """
        )
    }

    /// Pins the two seams that keep imports away from the real library, so
    /// removing either fails here rather than silently in someone's archive.
    @Test func theCoordinatorAndLibraryPathBothAcceptAnOverride() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("guard-\(UUID().uuidString)", isDirectory: true)

        // The catalog save destination must be injectable — this is the seam whose
        // absence let import tests overwrite the real catalog.
        let coordinator = PipelinedImportCoordinator(
            catalogService: CatalogService(),
            encryptionService: EncryptionService(),
            catalogURL: scratch.appendingPathComponent("catalog.json")
        )
        _ = coordinator

        // And the library root must be redirectable for UI tests, which launch the
        // real app binary against the real archive otherwise.
        #expect(Constants.Paths.uiTestLibraryEnvKey == "LUMIVAULT_UITEST_LIBRARY")
    }

    // MARK: - Sandbox isolation
    //
    // The predicate below is the single thing the whole sandbox layer rests on, and it
    // fails *open* — a toolchain change that stops `isTestProcess` firing puts every
    // subsequent run back on the production archive, silently. So it is asserted
    // directly rather than inferred from the redirects working.

    @Test func thisProcessIsRecognisedAsATestRunner() {
        #expect(
            Constants.Paths.isTestProcess,
            """
            Test-process detection has stopped working. Every path below resolves to the \
            real archive until it is fixed. Under `swift test` this relies on \
            `Bundle.main.bundleIdentifier` being nil (the host is swiftpm-testing-helper); \
            under `xcodebuild test` on XCTestConfigurationFilePath being set.
            """
        )
        #expect(!Constants.Paths.resolvesProductionLibrary)
    }

    @Test func everyWritableRootResolvesInsideTheSandbox() {
        let production = Constants.Paths.productionLibraryURL.path

        // One assertion per root. Covering only the library would leave the two that
        // reached `URL.applicationSupportDirectory` directly unguarded — they were
        // isolated by accident, and the accident is what this replaces.
        #expect(Constants.Paths.libraryURL.path != production,
                "libraryURL resolves to the real archive")
        #expect(!Constants.Paths.resolvedCatalogURL.path.hasPrefix(production),
                "resolvedCatalogURL points inside the real archive")
        #expect(Constants.Paths.applicationSupportURL != URL.applicationSupportDirectory,
                "applicationSupportURL is the real one — the store and thumbnail cache follow it")
        #expect(SwiftDataContainer.defaultStoreURL.path
                    .hasPrefix(Constants.Paths.sandboxRootURL.path),
                "the SwiftData store would open outside the sandbox")
        #expect(ThumbnailService.defaultCacheRoot.path
                    .hasPrefix(Constants.Paths.sandboxRootURL.path),
                "thumbnails would be written outside the sandbox")
    }

    @Test func theSandboxRootIsStableWithinTheProcess() {
        // Accessors must agree on one directory; a computed property returning a fresh
        // UUID each call would scatter the store, catalog and thumbnails across
        // unrelated temp directories and make the guards above pass while nothing lined
        // up.
        #expect(Constants.Paths.sandboxRootURL == Constants.Paths.sandboxRootURL)
        #expect(Constants.Paths.libraryURL == Constants.Paths.libraryURL)
    }
}

private extension JSONDecoder {
    static var catalogDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
