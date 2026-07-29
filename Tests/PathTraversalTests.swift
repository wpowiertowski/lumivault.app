import Testing
import Foundation
@testable import LumiVault

// MARK: - Path Component Validation

@Suite
@MainActor
struct PathComponentValidationTests {
    @Test func acceptsOrdinaryNames() {
        #expect(PathComponentValidation.isSafe("sunset.jpg"))
        #expect(PathComponentValidation.isSafe("IMG_1234.HEIC"))
        #expect(PathComponentValidation.isSafe("Vacation 2025"))
        #expect(PathComponentValidation.isSafe("file.par2"))
        #expect(PathComponentValidation.isSafe("2025"))
    }

    @Test func rejectsTraversalAndSeparators() {
        #expect(!PathComponentValidation.isSafe(".."))
        #expect(!PathComponentValidation.isSafe("."))
        #expect(!PathComponentValidation.isSafe(""))
        #expect(!PathComponentValidation.isSafe("../evil.jpg"))
        #expect(!PathComponentValidation.isSafe("../../../../etc/passwd"))
        #expect(!PathComponentValidation.isSafe("sub/dir.jpg"))
        #expect(!PathComponentValidation.isSafe("back\\slash.jpg"))
        #expect(!PathComponentValidation.isSafe("/absolute.jpg"))
        #expect(!PathComponentValidation.isSafe("nul\0byte.jpg"))
    }

    @Test func imageValidationRequiresAllComponents() {
        // par2 may be empty
        #expect(PathComponentValidation.isSafeImage(
            year: "2025", month: "07", day: "15", albumName: "Vacation",
            filename: "a.jpg", par2Filename: ""
        ))
        // traversing filename rejected
        #expect(!PathComponentValidation.isSafeImage(
            year: "2025", month: "07", day: "15", albumName: "Vacation",
            filename: "../a.jpg", par2Filename: ""
        ))
        // traversing album rejected
        #expect(!PathComponentValidation.isSafeImage(
            year: "2025", month: "07", day: "15", albumName: "../..",
            filename: "a.jpg", par2Filename: ""
        ))
        // traversing par2 rejected
        #expect(!PathComponentValidation.isSafeImage(
            year: "2025", month: "07", day: "15", albumName: "Vacation",
            filename: "a.jpg", par2Filename: "../a.par2"
        ))
    }
}

// MARK: - URL.isDescendant

@Suite
@MainActor
struct URLDescendantTests {
    @Test func descendantTruthTable() {
        let root = URL(fileURLWithPath: "/Volumes/Backup/2025/07/15/Vacation", isDirectory: true)

        #expect(root.appendingPathComponent("photo.jpg").isDescendant(of: root))
        #expect(root.isDescendant(of: root)) // self counts as descendant

        // A traversing component escapes and must be rejected
        let escaped = root.appendingPathComponent("../../../../etc/passwd")
        #expect(!escaped.isDescendant(of: root))

        // Sibling with shared prefix is NOT a descendant
        let sibling = URL(fileURLWithPath: "/Volumes/Backup/2025/07/15/VacationEvil/x.jpg")
        #expect(!sibling.isDescendant(of: root))
    }
}

// MARK: - Catalog Merge Sanitization

@Suite
@MainActor
struct CatalogMergeSanitizationTests {
    /// Build a single-image catalog with arbitrary path keys/filename.
    private func makeCatalog(
        year: String, month: String, day: String, album: String, filename: String
    ) -> Catalog {
        let image = CatalogImage(
            filename: filename, sha256: "abc123", sizeBytes: 1, par2Filename: ""
        )
        let albumEntry = CatalogAlbum(addedAt: .now, images: [image])
        let dayEntry = CatalogDay(albums: [album: albumEntry])
        let monthEntry = CatalogMonth(days: [day: dayEntry])
        let yearEntry = CatalogYear(months: [month: monthEntry])
        return Catalog(version: 1, lastUpdated: .now, years: [year: yearEntry])
    }

    @Test func mergeDropsTraversingFilename() async {
        let service = CatalogService()
        let remote = makeCatalog(
            year: "2025", month: "07", day: "15", album: "Vacation",
            filename: "../../../../evil.jpg"
        )
        let merged = await service.merge(remote: remote)
        let images = merged.years["2025"]?.months["07"]?.days["15"]?.albums["Vacation"]?.images ?? []
        #expect(images.isEmpty)
    }

    @Test func mergeDropsTraversingAlbum() async {
        let service = CatalogService()
        let remote = makeCatalog(
            year: "2025", month: "07", day: "15", album: "../..",
            filename: "ok.jpg"
        )
        let merged = await service.merge(remote: remote)
        let day = merged.years["2025"]?.months["07"]?.days["15"]
        #expect(day?.albums["../.."] == nil)
    }

    @Test func mergeKeepsCleanEntries() async {
        let service = CatalogService()
        let remote = makeCatalog(
            year: "2025", month: "07", day: "15", album: "Vacation",
            filename: "sunset.jpg"
        )
        let merged = await service.merge(remote: remote)
        let images = merged.years["2025"]?.months["07"]?.days["15"]?.albums["Vacation"]?.images ?? []
        #expect(images.count == 1)
        #expect(images.first?.filename == "sunset.jpg")
    }
}

// MARK: - Catalog Path Resolution (regression: f3c5fae, 2f44cfb)
//
// Apple rejected 1.0 under guideline 2.4.5(i) because the catalog lived inside the
// hidden sandbox container and Settings displayed that container path. The fix
// moved it to `~/Pictures/LumiVault` and resolves symlinks so the UI shows the real
// user-visible location — under the sandbox, `.picturesDirectory` returns a
// container-scoped alias to `~/Pictures`.

// These drive `resolveCatalogURL(override:)` rather than setting
// `UserDefaults.standard["catalogPath"]` around each assertion. That key is
// process-wide, and `.serialized` only orders tests *within* a suite — every
// other suite still runs concurrently, so a temporarily overridden catalog path
// would be visible to anything that reaches `resolvedCatalogURL` (catalogService
// .save(to:), migrateLegacyCatalogIfNeeded) at that moment. Passing the override
// in tests the same resolution with no shared mutable state.

@Suite
@MainActor
struct CatalogPathResolutionTests {

    @Test func defaultsToCatalogJSONInsideTheLibrary() {
        let url = Constants.Paths.resolveCatalogURL(override: nil)
        #expect(url.lastPathComponent == "catalog.json")
        #expect(url.deletingLastPathComponent().path == Constants.Paths.libraryURL.path)
    }

    @Test func honoursAnExplicitOverrideAndExpandsTilde() {
        #expect(Constants.Paths.resolveCatalogURL(override: "/Volumes/Archive/catalog.json").path
                == "/Volumes/Archive/catalog.json")

        let tilde = Constants.Paths.resolveCatalogURL(override: "~/Documents/catalog.json")
        #expect(tilde.path == ("~/Documents/catalog.json" as NSString).expandingTildeInPath)
        #expect(!tilde.path.hasPrefix("~"))
    }

    @Test func theLiveAccessorReadsTheOverrideKeyItDocuments() {
        // The split above is only safe while `resolvedCatalogURL` still feeds the
        // same key into the same function, so pin that wiring — without leaving a
        // mutated global behind for a concurrently running suite to trip over.
        let key = Constants.Paths.catalogPathDefaultsKey
        #expect(key == "catalogPath")
        let expected = Constants.Paths.resolveCatalogURL(
            override: UserDefaults.standard.string(forKey: key),
            uiTestLibrary: Constants.Paths.uiTestLibraryOverride
        )
        #expect(Constants.Paths.resolvedCatalogURL == expected)
    }

    @Test func theUITestLibraryBeatsTheUserConfiguredCatalogPath() {
        // Redirecting `libraryURL` was not enough on its own: `resolvedCatalogURL`
        // read the `catalogPath` default first, so a developer who had pointed it at
        // their real archive got that archive's catalog.json rewritten by a UI-driven
        // import — precisely what the UI-test override was added to prevent.
        let sandbox = URL(fileURLWithPath: "/tmp/lumivault-uitest-library")
        let url = Constants.Paths.resolveCatalogURL(
            override: "~/Pictures/LumiVault/catalog.json",
            uiTestLibrary: sandbox
        )
        #expect(url.path == "/tmp/lumivault-uitest-library/catalog.json")
    }

    @Test func libraryPathIsSymlinkResolvedAndUserVisible() {
        let library = Constants.Paths.libraryURL
        // Resolving is what keeps a container alias out of the Settings UI.
        #expect(library.path == library.resolvingSymlinksInPath().path)
        #expect(library.lastPathComponent == "LumiVault")
    }

    @Test func legacyContainerCatalogPathIsDistinctFromTheLibrary() {
        // Migration only makes sense while these two differ; if they ever collide
        // the launch-time move would be a no-op that silently strands a catalog.
        let legacy = Constants.Paths.legacyContainerCatalogURL
        #expect(legacy.lastPathComponent == "catalog.json")
        #expect(legacy.deletingLastPathComponent().path != Constants.Paths.libraryURL.path)
        #expect(!legacy.path.hasPrefix("~"))
    }
}
