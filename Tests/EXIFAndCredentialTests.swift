import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreLocation
@testable import LumiVault

// MARK: - EXIF
//
// `EXIFData` was 7.1% covered: only `exposureString` had tests, and only because
// a corrupt zero-exposure tag used to trap (`Int(round(1.0/0))`). Everything else
// — the other six formatters, the ImageIO extraction, and the GPS hemisphere
// handling — was unexercised.
//
// The GPS case is the one that matters. Latitude and longitude are stored as
// unsigned magnitudes with a separate N/S/E/W reference tag, so the sign is
// reconstructed by the reader. Getting that wrong does not crash and does not
// fail to decode; it silently files the photo on the wrong side of the equator
// or the prime meridian.

@Suite
@MainActor
struct EXIFExtractionTests {

    /// Write a real JPEG carrying the given EXIF/TIFF/GPS dictionaries.
    private func writeImage(
        to url: URL,
        exif: [CFString: Any] = [:],
        tiff: [CFString: Any] = [:],
        gps: [CFString: Any] = [:],
        width: Int = 8,
        height: Int = 4
    ) throws {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0x7F, count: bytesPerRow * height)
        let context = try #require(pixels.withUnsafeMutableBytes { buf in
            CGContext(
                data: buf.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        })
        let image = try #require(context.makeImage())

        let dest = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        var properties: [CFString: Any] = [:]
        if !exif.isEmpty { properties[kCGImagePropertyExifDictionary] = exif }
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiff }
        if !gps.isEmpty { properties[kCGImagePropertyGPSDictionary] = gps }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-exif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - GPS sign reconstruction

    @Test func southernAndWesternCoordinatesAreNegated() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sydney.jpg")

        // Sydney: 33.87°S, 151.21°E — EXIF stores magnitudes plus a reference.
        try writeImage(to: url, gps: [
            kCGImagePropertyGPSLatitude: 33.8688,
            kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 151.2093,
            kCGImagePropertyGPSLongitudeRef: "E"
        ])

        let exif = try #require(EXIFData.extract(from: url))
        // A dropped negation puts this photo in Lebanon rather than Australia.
        #expect(abs(try #require(exif.latitude) - (-33.8688)) < 0.0001)
        #expect(abs(try #require(exif.longitude) - 151.2093) < 0.0001)
        #expect(exif.hasGPS)
    }

    @Test func northernAndWesternCoordinatesKeepAndFlipTheRightAxis() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nyc.jpg")

        // New York: 40.71°N, 74.01°W — only longitude flips.
        try writeImage(to: url, gps: [
            kCGImagePropertyGPSLatitude: 40.7128,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 74.0060,
            kCGImagePropertyGPSLongitudeRef: "W"
        ])

        let exif = try #require(EXIFData.extract(from: url))
        #expect(abs(try #require(exif.latitude) - 40.7128) < 0.0001)
        #expect(abs(try #require(exif.longitude) - (-74.0060)) < 0.0001)
    }

    @Test func anImageWithoutGPSReportsNoCoordinate() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nogps.jpg")
        try writeImage(to: url, exif: [kCGImagePropertyExifFNumber: 2.8])

        let exif = try #require(EXIFData.extract(from: url))
        #expect(!exif.hasGPS)
        #expect(exif.coordinate == nil)
        #expect(exif.coordinateString == nil)
    }

    // MARK: - Extraction of capture settings

    @Test func captureSettingsAndDimensionsAreReadFromTheFile() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shot.jpg")

        try writeImage(
            to: url,
            exif: [
                kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifFNumber: 1.8,
                kCGImagePropertyExifFocalLength: 26.0,
                kCGImagePropertyExifISOSpeedRatings: [400],
                kCGImagePropertyExifLensModel: "Test 26mm f/1.8"
            ],
            tiff: [
                kCGImagePropertyTIFFMake: "  TestCam  ",
                kCGImagePropertyTIFFModel: " Model X ",
                kCGImagePropertyTIFFDateTime: "2026:07:28 14:30:05"
            ],
            width: 12, height: 6
        )

        let exif = try #require(EXIFData.extract(from: url))
        #expect(exif.fNumber == 1.8)
        #expect(exif.iso == 400)          // read out of an array, not a scalar
        #expect(exif.focalLength == 26.0)
        #expect(exif.lensModel == "Test 26mm f/1.8")
        // Make/model are trimmed — camera vendors pad these with spaces.
        #expect(exif.cameraMake == "TestCam")
        #expect(exif.cameraModel == "Model X")
        #expect(exif.pixelWidth == 12)
        #expect(exif.pixelHeight == 6)
        #expect(exif.dateTaken != nil)
    }

    @Test func exifDatesParseInAFixedFormatRegardlessOfSystemLocale() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dated.jpg")
        // Only the EXIF date, no TIFF DateTime — this drives the fallback branch
        // (`if exif.dateTaken == nil, let … DateTimeOriginal`), which the
        // capture-settings test above never reaches because TIFF wins there.
        try writeImage(to: url, exif: [
            kCGImagePropertyExifDateTimeOriginal: "2026:07:28 14:30:05"
        ])

        let exif = try #require(EXIFData.extract(from: url))
        let date = try #require(exif.dateTaken)
        // Pinned against a fixed calendar: `yyyy:MM:dd HH:mm:ss` with a POSIX
        // locale, so a device on a non-Gregorian calendar still reads it.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(parts.year == 2026)
        #expect(parts.month == 7)
        #expect(parts.day == 28)
        #expect(parts.hour == 14)
        #expect(parts.minute == 30)
    }

    @Test func extractionOfANonImageReturnsNilRatherThanThrowing() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("notanimage.jpg")
        try Data("this is not a JPEG".utf8).write(to: url)

        #expect(EXIFData.extract(from: url) == nil)
        #expect(EXIFData.extract(from: Data("still not an image".utf8)) == nil)
    }

    @Test func extractionWorksFromInMemoryDataAsWellAsAURL() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mem.jpg")
        try writeImage(to: url, exif: [kCGImagePropertyExifFNumber: 4.0], width: 10, height: 5)

        // The decrypted-bytes path: same parse, no file on disk.
        let fromData = try #require(EXIFData.extract(from: try Data(contentsOf: url)))
        #expect(fromData.fNumber == 4.0)
        #expect(fromData.pixelWidth == 10)
    }
}

// MARK: - Formatted strings

@Suite
@MainActor
struct EXIFFormattingTests {

    @Test func apertureIsoAndFocalLengthFormat() {
        var exif = EXIFData()
        #expect(exif.fNumberString == nil)
        #expect(exif.isoString == nil)
        #expect(exif.focalLengthString == nil)

        exif.fNumber = 1.789
        exif.iso = 1600
        exif.focalLength = 23.4
        #expect(exif.fNumberString == "f/1.8")      // rounded to one decimal
        #expect(exif.isoString == "ISO 1600")
        #expect(exif.focalLengthString == "23mm")   // whole millimetres

        // The 35mm equivalent is appended only when present.
        exif.focalLength35mm = 70
        #expect(exif.focalLengthString == "23mm (70mm eq.)")
    }

    @Test func dimensionsReportMegapixelsAndNeedBothAxes() {
        var exif = EXIFData()
        exif.pixelWidth = 4032
        #expect(exif.dimensionsString == nil, "one axis alone is not a dimension")

        exif.pixelHeight = 3024
        // 4032 × 3024 = 12,192,768 → 12.2 MP
        #expect(exif.dimensionsString == "4032 × 3024 (12.2 MP)")
    }

    @Test func altitudeAndCoordinateStringsFormatToFixedPrecision() {
        var exif = EXIFData()
        #expect(exif.altitudeString == nil)
        #expect(exif.coordinateString == nil)

        exif.altitude = 1234.56
        #expect(exif.altitudeString == "1235 m")

        exif.latitude = -33.86882
        exif.longitude = 151.20930
        #expect(exif.coordinateString == "-33.86882, 151.20930")
        let coordinate = exif.coordinate
        #expect(coordinate != nil)
        #expect(abs((coordinate?.latitude ?? 0) - (-33.86882)) < 0.00001)
    }

    @Test func aLatitudeWithoutALongitudeIsNotACoordinate() {
        var exif = EXIFData()
        exif.latitude = 40.0
        // Half a fix is not a fix — the inspector must not plot it.
        #expect(!exif.hasGPS)
        #expect(exif.coordinate == nil)
        #expect(exif.coordinateString == nil)
    }
}

// MARK: - Keychain
//
// These touch the real login Keychain. They are gated off in CI, where the
// keychain is typically locked and `SecItemAdd` fails for reasons that have
// nothing to do with this code. Verified locally: set/get/delete round-trip
// cleanly and headlessly, with no authorization prompt.
//
// Every test uses a UUID-scoped account. `B2Credentials` deliberately has no
// tests here: it persists under a *fixed* account, so exercising its save/load
// would overwrite the developer's real Backblaze credentials.

@Suite
@MainActor
struct KeychainStoreTests {

    /// `nonisolated` so the `.enabled(if:)` trait — evaluated in a Sendable
    /// closure — can read it.
    nonisolated static var runsHere: Bool {
        ProcessInfo.processInfo.environment["CI"] == nil
    }

    @Test(.enabled(if: KeychainStoreTests.runsHere))
    func storedSecretsRoundTripAndDeleteCleanly() throws {
        let account = "lumivault.test.\(UUID().uuidString)"
        defer { KeychainStore.delete(account: account) }

        #expect(KeychainStore.get(account: account) == nil, "account should start empty")

        let secret = Data("application-key-material".utf8)
        try KeychainStore.set(secret, account: account)
        #expect(KeychainStore.get(account: account) == secret)

        KeychainStore.delete(account: account)
        #expect(KeychainStore.get(account: account) == nil)
    }

    @Test(.enabled(if: KeychainStoreTests.runsHere))
    func writingTwiceUpdatesInPlaceRatherThanFailingOrDuplicating() throws {
        let account = "lumivault.test.\(UUID().uuidString)"
        defer { KeychainStore.delete(account: account) }

        try KeychainStore.set(Data("first".utf8), account: account)
        // SecItemAdd on an existing item errors; `set` must take the update path.
        try KeychainStore.set(Data("second".utf8), account: account)

        #expect(KeychainStore.get(account: account) == Data("second".utf8))
    }

    @Test(.enabled(if: KeychainStoreTests.runsHere))
    func deletingAnAbsentAccountIsANoOp() {
        // Called on the "switch sync mode" path before re-adding, where the item
        // may legitimately not exist yet.
        KeychainStore.delete(account: "lumivault.test.absent.\(UUID().uuidString)")
    }

    @Test(.enabled(if: KeychainStoreTests.runsHere))
    func accountsAreIsolatedFromOneAnother() throws {
        let a = "lumivault.test.\(UUID().uuidString)"
        let b = "lumivault.test.\(UUID().uuidString)"
        defer { KeychainStore.delete(account: a); KeychainStore.delete(account: b) }

        try KeychainStore.set(Data("alpha".utf8), account: a)
        try KeychainStore.set(Data("beta".utf8), account: b)

        #expect(KeychainStore.get(account: a) == Data("alpha".utf8))
        #expect(KeychainStore.get(account: b) == Data("beta".utf8))

        KeychainStore.delete(account: a)
        #expect(KeychainStore.get(account: a) == nil)
        #expect(KeychainStore.get(account: b) == Data("beta".utf8), "deleting one account hit another")
    }
}
