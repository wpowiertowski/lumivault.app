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
