import Testing
import Foundation
@testable import LumiVault

@Suite
@MainActor
struct LumiVaultTests {
    @Test func catalogRoundTrip() throws {
        let image = CatalogImage(
            filename: "IMG_0001.heic",
            sha256: "abc123",
            sizeBytes: 4_200_000,
            par2Filename: "IMG_0001.heic.par2"
        )

        let album = CatalogAlbum(addedAt: .now, images: [image])
        let day = CatalogDay(albums: ["Vacation": album])
        let month = CatalogMonth(days: ["15": day])
        let year = CatalogYear(months: ["07": month])

        let catalog = Catalog(version: 1, lastUpdated: .now, years: ["2025": year])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(catalog)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Catalog.self, from: data)

        #expect(decoded.version == 1)
        #expect(decoded.years["2025"]?.months["07"]?.days["15"]?.albums["Vacation"]?.images.count == 1)
        #expect(decoded.years["2025"]?.months["07"]?.days["15"]?.albums["Vacation"]?.images.first?.sha256 == "abc123")
    }
}
