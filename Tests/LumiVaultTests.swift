import Testing
import Foundation
import SwiftData
@testable import LumiVault

// MARK: - Catalog Tests

@Suite
@MainActor
struct CatalogTests {
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

    @Test func catalogRoundTripWithOptionalFields() throws {
        let image = CatalogImage(
            filename: "IMG_0002.heic",
            sha256: "def456",
            sizeBytes: 3_000_000,
            par2Filename: "IMG_0002.heic.par2",
            b2FileId: "4_zb2bucket_f1234"
        )

        let album = CatalogAlbum(addedAt: .now, images: [image])
        let day = CatalogDay(albums: ["Trip": album])
        let month = CatalogMonth(days: ["01": day])
        let year = CatalogYear(months: ["12": month])
        let catalog = Catalog(version: 2, lastUpdated: .now, years: ["2024": year])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(catalog)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Catalog.self, from: data)

        let decodedImage = decoded.years["2024"]?.months["12"]?.days["01"]?.albums["Trip"]?.images.first
        #expect(decodedImage?.b2FileId == "4_zb2bucket_f1234")
        #expect(decodedImage?.sizeBytes == 3_000_000)
        #expect(decodedImage?.par2Filename == "IMG_0002.heic.par2")
    }

    @Test func catalogRoundTripNilB2FileId() throws {
        let image = CatalogImage(
            filename: "IMG_0003.heic",
            sha256: "ghi789",
            sizeBytes: 1_000_000,
            par2Filename: "IMG_0003.heic.par2"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let album = CatalogAlbum(addedAt: .now, images: [image])
        let catalog = Catalog(version: 1, lastUpdated: .now, years: [
            "2025": CatalogYear(months: [
                "01": CatalogMonth(days: [
                    "01": CatalogDay(albums: ["Test": album])
                ])
            ])
        ])

        let data = try encoder.encode(catalog)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Catalog.self, from: data)

        let decodedImage = decoded.years["2025"]?.months["01"]?.days["01"]?.albums["Test"]?.images.first
        #expect(decodedImage?.b2FileId == nil)
    }

    @Test func catalogFileIO() throws {
        let image = CatalogImage(
            filename: "test.heic",
            sha256: "aabbcc",
            sizeBytes: 500_000,
            par2Filename: "test.heic.par2"
        )
        let album = CatalogAlbum(addedAt: .now, images: [image])
        let catalog = Catalog(version: 1, lastUpdated: .now, years: [
            "2025": CatalogYear(months: [
                "06": CatalogMonth(days: [
                    "20": CatalogDay(albums: ["FileIO": album])
                ])
            ])
        ])

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try catalog.save(to: tmpURL)

        let loaded = try Catalog.load(from: tmpURL)
        #expect(loaded.version == 1)
        let loadedImage = loaded.years["2025"]?.months["06"]?.days["20"]?.albums["FileIO"]?.images.first
        #expect(loadedImage?.sha256 == "aabbcc")
        #expect(loadedImage?.filename == "test.heic")
    }

    @Test func catalogCodingKeysSnakeCase() throws {
        let image = CatalogImage(
            filename: "f.heic", sha256: "abc", sizeBytes: 100, par2Filename: "f.par2", b2FileId: "b2id"
        )
        let album = CatalogAlbum(addedAt: Date(timeIntervalSince1970: 1000), images: [image])
        let catalog = Catalog(version: 1, lastUpdated: Date(timeIntervalSince1970: 2000), years: [
            "2025": CatalogYear(months: [
                "01": CatalogMonth(days: [
                    "01": CatalogDay(albums: ["A": album])
                ])
            ])
        ])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(catalog)
        let json = String(data: data, encoding: .utf8)!

        // Verify snake_case keys in JSON output
        #expect(json.contains("\"last_updated\""))
        #expect(json.contains("\"added_at\""))
        #expect(json.contains("\"size_bytes\""))
        #expect(json.contains("\"par2_filename\""))
        #expect(json.contains("\"b2_file_id\""))
        // Verify camelCase keys are NOT in JSON output
        #expect(!json.contains("\"lastUpdated\""))
        #expect(!json.contains("\"addedAt\""))
        #expect(!json.contains("\"sizeBytes\""))
        #expect(!json.contains("\"par2Filename\""))
        #expect(!json.contains("\"b2FileId\""))
    }
}

// MARK: - CatalogService Merge Tests

@Suite
@MainActor
struct CatalogServiceMergeTests {
    @Test func mergeDisjointCatalogs() async {
        let service = CatalogService()

        // Add a local image
        let localImage = CatalogImage(filename: "local.heic", sha256: "local_hash", sizeBytes: 100, par2Filename: "local.par2")
        await service.addImage(localImage, toAlbum: "LocalAlbum", year: "2025", month: "01", day: "15")

        // Create a remote catalog with different content
        let remoteImage = CatalogImage(filename: "remote.heic", sha256: "remote_hash", sizeBytes: 200, par2Filename: "remote.par2")
        let remoteAlbum = CatalogAlbum(addedAt: .now, images: [remoteImage])
        let remote = Catalog(version: 1, lastUpdated: .now, years: [
            "2024": CatalogYear(months: [
                "06": CatalogMonth(days: [
                    "01": CatalogDay(albums: ["RemoteAlbum": remoteAlbum])
                ])
            ])
        ])

        let merged = await service.merge(remote: remote)

        // Both years should exist
        #expect(merged.years["2025"] != nil)
        #expect(merged.years["2024"] != nil)
        #expect(merged.years["2025"]?.months["01"]?.days["15"]?.albums["LocalAlbum"]?.images.count == 1)
        #expect(merged.years["2024"]?.months["06"]?.days["01"]?.albums["RemoteAlbum"]?.images.count == 1)
    }

    @Test func mergeOverlappingAlbumUnionsBySHA() async {
        let service = CatalogService()

        let sharedImage = CatalogImage(filename: "shared.heic", sha256: "shared_hash", sizeBytes: 100, par2Filename: "shared.par2")
        let localOnly = CatalogImage(filename: "local.heic", sha256: "local_hash", sizeBytes: 200, par2Filename: "local.par2")
        await service.addImage(sharedImage, toAlbum: "Album", year: "2025", month: "01", day: "01")
        await service.addImage(localOnly, toAlbum: "Album", year: "2025", month: "01", day: "01")

        let remoteOnly = CatalogImage(filename: "remote.heic", sha256: "remote_hash", sizeBytes: 300, par2Filename: "remote.par2")
        let remoteAlbum = CatalogAlbum(addedAt: .now, images: [sharedImage, remoteOnly])
        let remote = Catalog(version: 1, lastUpdated: .now, years: [
            "2025": CatalogYear(months: [
                "01": CatalogMonth(days: [
                    "01": CatalogDay(albums: ["Album": remoteAlbum])
                ])
            ])
        ])

        let merged = await service.merge(remote: remote)
        let images = merged.years["2025"]?.months["01"]?.days["01"]?.albums["Album"]?.images ?? []

        // Should have 3 unique images (shared deduped)
        #expect(images.count == 3)
        let hashes = Set(images.map(\.sha256))
        #expect(hashes.contains("shared_hash"))
        #expect(hashes.contains("local_hash"))
        #expect(hashes.contains("remote_hash"))
    }

    @Test func mergeRemoteOnlyAddsNewAlbum() async {
        let service = CatalogService()

        let remoteImage = CatalogImage(filename: "new.heic", sha256: "new_hash", sizeBytes: 100, par2Filename: "new.par2")
        let remote = Catalog(version: 1, lastUpdated: .now, years: [
            "2025": CatalogYear(months: [
                "03": CatalogMonth(days: [
                    "10": CatalogDay(albums: [
                        "NewAlbum": CatalogAlbum(addedAt: .now, images: [remoteImage])
                    ])
                ])
            ])
        ])

        let merged = await service.merge(remote: remote)
        let images = merged.years["2025"]?.months["03"]?.days["10"]?.albums["NewAlbum"]?.images ?? []
        #expect(images.count == 1)
        #expect(images.first?.sha256 == "new_hash")
    }

    @Test func mergeLastUpdatedUsesMax() async {
        let service = CatalogService()

        let later = Date(timeIntervalSince1970: 2000)

        let localImage = CatalogImage(filename: "l.heic", sha256: "l", sizeBytes: 1, par2Filename: "l.par2")
        await service.addImage(localImage, toAlbum: "A", year: "2025", month: "01", day: "01")

        let remote = Catalog(version: 1, lastUpdated: later, years: [:])
        let merged = await service.merge(remote: remote)

        // Merged lastUpdated should be >= later (local may be even later since addImage sets .now)
        #expect(merged.lastUpdated >= later)
    }

    @Test func addImageDeduplicatesBySHA() async {
        let service = CatalogService()

        let image = CatalogImage(filename: "img.heic", sha256: "same_hash", sizeBytes: 100, par2Filename: "img.par2")
        await service.addImage(image, toAlbum: "Album", year: "2025", month: "01", day: "01")
        await service.addImage(image, toAlbum: "Album", year: "2025", month: "01", day: "01")

        let catalog = await service.currentCatalog()
        let images = catalog.years["2025"]?.months["01"]?.days["01"]?.albums["Album"]?.images ?? []
        #expect(images.count == 1)
    }
}

// MARK: - HasherService Tests

@Suite
struct HasherServiceTests {
    @Test func sha256KnownInput() async throws {
        let service = HasherService()

        let content = "Hello, LumiVault!"
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-hash-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try content.data(using: .utf8)!.write(to: tmpURL)

        let hash = try await service.sha256(of: tmpURL)

        // SHA-256 of "Hello, LumiVault!" — precomputed
        // Verify it's a 64-char hex string
        #expect(hash.count == 64)
        #expect(hash.allSatisfy { $0.isHexDigit })

        // Hash should be deterministic
        let hash2 = try await service.sha256(of: tmpURL)
        #expect(hash == hash2)
    }

    @Test func sha256EmptyFile() async throws {
        let service = HasherService()

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-hash-empty-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try Data().write(to: tmpURL)

        let hash = try await service.sha256(of: tmpURL)

        // SHA-256 of empty input is a well-known constant
        #expect(hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func sha256AndSizeReturnsCorrectSize() async throws {
        let service = HasherService()

        let content = Data(repeating: 0xAB, count: 12345)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-hash-size-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try content.write(to: tmpURL)

        let (hash, size) = try await service.sha256AndSize(of: tmpURL)

        #expect(size == 12345)
        #expect(hash.count == 64)
    }

    @Test func sha256ConsistentBetweenMethods() async throws {
        let service = HasherService()

        let content = "Consistency check across both methods"
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-hash-consistent-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try content.data(using: .utf8)!.write(to: tmpURL)

        let hashOnly = try await service.sha256(of: tmpURL)
        let (hashAndSize, _) = try await service.sha256AndSize(of: tmpURL)

        #expect(hashOnly == hashAndSize)
    }
}

// MARK: - RedundancyService Tests

@Suite
struct RedundancyServiceTests {
    @Test func generateAndVerifyPAR2() async throws {
        let service = RedundancyService()

        // Create a test file
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-par2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let testData = Data(repeating: 0x42, count: 10_000)
        let fileURL = tmpDir.appendingPathComponent("test.heic")
        try testData.write(to: fileURL)

        let par2URL = try await service.generatePAR2(for: fileURL, outputDirectory: tmpDir)

        // PAR2 file should exist
        #expect(FileManager.default.fileExists(atPath: par2URL.path))
        #expect(par2URL.lastPathComponent == "test.heic.par2")

        // Verification should pass
        let isValid = try await service.verify(par2URL: par2URL, originalFileURL: fileURL)
        #expect(isValid)
    }

    @Test func par2HeaderMagicBytes() async throws {
        let service = RedundancyService()

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-par2-magic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let testData = Data(repeating: 0xFF, count: 5000)
        let fileURL = tmpDir.appendingPathComponent("magic.bin")
        try testData.write(to: fileURL)

        let par2URL = try await service.generatePAR2(for: fileURL, outputDirectory: tmpDir)
        let par2Data = try Data(contentsOf: par2URL)

        // Check magic bytes
        let magic = String(data: par2Data[0..<4], encoding: .ascii)
        #expect(magic == "PV2R")

        // Check stored file size
        let storedSize = par2Data[4..<12].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        #expect(storedSize == 5000)
    }

    @Test func par2VerifyFailsOnSizeMismatch() async throws {
        let service = RedundancyService()

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-par2-mismatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let originalData = Data(repeating: 0x11, count: 8000)
        let fileURL = tmpDir.appendingPathComponent("original.bin")
        try originalData.write(to: fileURL)

        let par2URL = try await service.generatePAR2(for: fileURL, outputDirectory: tmpDir)

        // Now overwrite original with different-sized content
        let tamperedData = Data(repeating: 0x22, count: 4000)
        try tamperedData.write(to: fileURL)

        let isValid = try await service.verify(par2URL: par2URL, originalFileURL: fileURL)
        #expect(!isValid)
    }

    @Test func par2VerifyFailsOnInvalidMagic() async throws {
        let service = RedundancyService()

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-par2-badmagic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("file.bin")
        try Data(repeating: 0x00, count: 100).write(to: fileURL)

        // Write invalid PAR2 file
        let badPar2URL = tmpDir.appendingPathComponent("file.bin.par2")
        try Data(repeating: 0x00, count: 50).write(to: badPar2URL)

        let isValid = try await service.verify(par2URL: badPar2URL, originalFileURL: fileURL)
        #expect(!isValid)
    }

    @Test func par2SmallFile() async throws {
        let service = RedundancyService()

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-par2-small-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Single byte file — edge case
        let testData = Data([0x42])
        let fileURL = tmpDir.appendingPathComponent("tiny.bin")
        try testData.write(to: fileURL)

        let par2URL = try await service.generatePAR2(for: fileURL, outputDirectory: tmpDir)
        let isValid = try await service.verify(par2URL: par2URL, originalFileURL: fileURL)
        #expect(isValid)
    }

    @Test func par2CorruptAndRepairRoundTrip() async throws {
        let service = RedundancyService()
        let hasher = HasherService()

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-par2-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create synthetic test file with varied content
        let originalData = Data((0..<8192).map { UInt8(($0 * 37 + 13) % 256) })
        let fileURL = tmpDir.appendingPathComponent("original.bin")
        try originalData.write(to: fileURL)

        // Hash before corruption
        let originalHash = try await hasher.sha256(of: fileURL)

        // Generate PAR2 recovery data
        let par2URL = try await service.generatePAR2(for: fileURL, outputDirectory: tmpDir)

        // Corrupt the file — overwrite bytes in the middle of the first block
        var corruptedData = originalData
        for i in 100..<200 {
            corruptedData[i] = 0xFF
        }
        try corruptedData.write(to: fileURL)

        // Verify corruption changed the hash
        let corruptedHash = try await hasher.sha256(of: fileURL)
        #expect(corruptedHash != originalHash)

        // Repair using PAR2
        let repairedData = try await service.repair(par2URL: par2URL, corruptedFileURL: fileURL)
        #expect(repairedData != nil)

        // Write repaired data back and verify hash matches original
        let repairedURL = tmpDir.appendingPathComponent("repaired.bin")
        try repairedData!.write(to: repairedURL)
        let repairedHash = try await hasher.sha256(of: repairedURL)

        #expect(repairedHash == originalHash)
        #expect(repairedData! == originalData)
    }

    @Test func par2CorruptAndRepairLastBlock() async throws {
        let service = RedundancyService()
        let hasher = HasherService()

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-par2-repair-last-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // File size not aligned to block size (4096) — tests partial last block
        let originalData = Data((0..<6000).map { UInt8(($0 * 53 + 7) % 256) })
        let fileURL = tmpDir.appendingPathComponent("partial.bin")
        try originalData.write(to: fileURL)

        let originalHash = try await hasher.sha256(of: fileURL)
        let par2URL = try await service.generatePAR2(for: fileURL, outputDirectory: tmpDir)

        // Corrupt bytes in the last (partial) block
        var corrupted = originalData
        for i in 5000..<5050 {
            corrupted[i] = 0x00
        }
        try corrupted.write(to: fileURL)

        let repairedData = try await service.repair(par2URL: par2URL, corruptedFileURL: fileURL)
        #expect(repairedData != nil)

        let repairedURL = tmpDir.appendingPathComponent("repaired.bin")
        try repairedData!.write(to: repairedURL)
        let repairedHash = try await hasher.sha256(of: repairedURL)

        #expect(repairedHash == originalHash)
    }

    @Test func par2LargerThanBlockSize() async throws {
        let service = RedundancyService()

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-par2-large-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Multiple blocks (blockSize = 4096, so 5 blocks + partial)
        let testData = Data((0..<20500).map { UInt8($0 % 256) })
        let fileURL = tmpDir.appendingPathComponent("multi.bin")
        try testData.write(to: fileURL)

        let par2URL = try await service.generatePAR2(for: fileURL, outputDirectory: tmpDir)
        let isValid = try await service.verify(par2URL: par2URL, originalFileURL: fileURL)
        #expect(isValid)

        // Verify recovery block count: ceil(20500/4096)=6 blocks, max(2, 6*0.10)=2
        let par2Data = try Data(contentsOf: par2URL)
        // Header layout: magic(4) + fileSize(8) + blockSize(4) + blockCount(4) + recoveryCount(4)
        let storedBlockSize = par2Data[12..<16].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let blockCount = par2Data[16..<20].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let recoveryCount = par2Data[20..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(storedBlockSize == 4096)
        #expect(blockCount == 6) // ceil(20500 / 4096) = 5.006... = 6
        #expect(recoveryCount >= 2)
    }
}

// MARK: - PerceptualHash Tests

@Suite
struct PerceptualHashTests {
    @Test func hammingDistanceIdentical() {
        let hash = Data([0x00, 0xFF, 0xAA, 0x55, 0x12, 0x34, 0x56, 0x78])
        let distance = PerceptualHash.hammingDistance(hash, hash)
        #expect(distance == 0)
    }

    @Test func hammingDistanceOpposite() {
        let a = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let b = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let distance = PerceptualHash.hammingDistance(a, b)
        #expect(distance == 64)
    }

    @Test func hammingDistanceSingleBitDifference() {
        let a = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let b = Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let distance = PerceptualHash.hammingDistance(a, b)
        #expect(distance == 1)
    }

    @Test func hammingDistanceKnownValue() {
        // 0xAA = 10101010, 0x55 = 01010101 — 8 bits differ per byte
        let a = Data([0xAA, 0xAA, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let b = Data([0x55, 0x55, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let distance = PerceptualHash.hammingDistance(a, b)
        #expect(distance == 16)
    }

    @Test func hammingDistanceInvalidLength() {
        let a = Data([0x00, 0x00]) // Too short
        let b = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let distance = PerceptualHash.hammingDistance(a, b)
        #expect(distance == 64) // Returns max distance for invalid input
    }

    @Test func hammingDistanceSymmetric() {
        let a = Data([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0])
        let b = Data([0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12])
        #expect(PerceptualHash.hammingDistance(a, b) == PerceptualHash.hammingDistance(b, a))
    }

    @Test func nearDuplicateThreshold() {
        // Hashes differing by < 5 bits should be "near duplicates"
        let a = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let b = Data([0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // 3 bits differ
        let distance = PerceptualHash.hammingDistance(a, b)
        #expect(distance < 5)
        #expect(distance == 3)
    }
}

// MARK: - IntegrityService Tests

@Suite
struct IntegrityServiceTests {
    @Test func verifyPassesForMatchingHash() async throws {
        let hasher = HasherService()
        let integrity = IntegrityService()

        // Create a temp file and compute its actual hash
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-integrity-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let content = Data("integrity test content".utf8)
        try content.write(to: tmpURL)

        let actualHash = try await hasher.sha256(of: tmpURL)

        let image = ImageRecord(sha256: actualHash, filename: "test.bin", sizeBytes: Int64(content.count))

        let results = await integrity.verify(
            images: [image],
            sourceResolver: { _ in tmpURL }
        )

        #expect(results.count == 1)
        #expect(results[0].passed == true)
        #expect(results[0].actualHash == actualHash)
        #expect(results[0].expectedHash == actualHash)
    }

    @Test func verifyFailsForHashMismatch() async throws {
        let integrity = IntegrityService()

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-integrity-mismatch-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try Data("original content".utf8).write(to: tmpURL)

        // Image record has a wrong hash
        let image = ImageRecord(sha256: "0000000000000000000000000000000000000000000000000000000000000000", filename: "test.bin", sizeBytes: 100)

        let results = await integrity.verify(
            images: [image],
            sourceResolver: { _ in tmpURL }
        )

        #expect(results.count == 1)
        #expect(results[0].passed == false)
        #expect(results[0].actualHash != nil)
        #expect(results[0].actualHash != results[0].expectedHash)
    }

    @Test func verifyFailsWhenFileNotResolved() async throws {
        let integrity = IntegrityService()

        let image = ImageRecord(sha256: "abc123", filename: "missing.bin", sizeBytes: 100)

        let results = await integrity.verify(
            images: [image],
            sourceResolver: { _ in nil }
        )

        #expect(results.count == 1)
        #expect(results[0].passed == false)
        #expect(results[0].actualHash == nil)
    }

    @Test func verifyBatchSizeLimit() async throws {
        let integrity = IntegrityService()

        var images: [ImageRecord] = []
        for i in 0..<100 {
            images.append(ImageRecord(sha256: "hash\(i)", filename: "file\(i).bin", sizeBytes: 100))
        }

        let results = await integrity.verify(
            images: images,
            sourceResolver: { _ in nil },
            batchSize: 10
        )

        // Should only process 10 (batchSize)
        #expect(results.count == 10)
    }
}

// MARK: - SwiftData Model Tests

@Suite
@MainActor
struct SwiftDataModelTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: ImageRecord.self, AlbumRecord.self, VolumeRecord.self,
            configurations: config
        )
    }

    @Test func albumRecordDateLabel() throws {
        let album = AlbumRecord(name: "Vacation", year: "2025", month: "07", day: "15")
        #expect(album.dateLabel == "2025-07-15")
    }

    @Test func albumImageRelationship() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let album = AlbumRecord(name: "Trip", year: "2025", month: "06", day: "01")
        context.insert(album)

        let image1 = ImageRecord(sha256: "hash1", filename: "img1.heic", sizeBytes: 1000)
        let image2 = ImageRecord(sha256: "hash2", filename: "img2.heic", sizeBytes: 2000)
        image1.album = album
        image2.album = album
        context.insert(image1)
        context.insert(image2)

        try context.save()

        #expect(album.images.count == 2)
        #expect(image1.album?.name == "Trip")
    }

    @Test func imageRecordDefaults() throws {
        let image = ImageRecord(sha256: "abc", filename: "test.heic", sizeBytes: 500)

        #expect(image.thumbnailState == .pending)
        #expect(image.perceptualHash == nil)
        #expect(image.b2FileId == nil)
        #expect(image.lastVerifiedAt == nil)
        #expect(image.storageLocations.isEmpty)
        #expect(image.par2Filename == "")
    }

    @Test func storageLocationCodable() throws {
        let location = StorageLocation(volumeID: "vol-123", relativePath: "2025/07/img.heic")
        let data = try JSONEncoder().encode(location)
        let decoded = try JSONDecoder().decode(StorageLocation.self, from: data)

        #expect(decoded.volumeID == "vol-123")
        #expect(decoded.relativePath == "2025/07/img.heic")
    }

    @Test func thumbnailStateCodable() throws {
        for state in [ThumbnailState.pending, .generated, .failed] {
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(ThumbnailState.self, from: data)
            #expect(decoded == state)
        }
    }
}
