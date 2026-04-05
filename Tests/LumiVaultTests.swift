import Testing
import Foundation
import SwiftData
@testable import LumiVault

// MARK: - Catalog Tests

@Suite
@MainActor
struct CatalogTests {
    @Test func catalogRoundTripFromFixtures() throws {
        let catalog = TestFixtures.catalog()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(catalog)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Catalog.self, from: data)

        #expect(decoded.version == 1)
        // Vacation album should have 3 images
        let vacationImages = decoded.years["2025"]?.months["07"]?.days["15"]?.albums["Vacation"]?.images ?? []
        #expect(vacationImages.count == 3)
        let vacationHashes = Set(vacationImages.map(\.sha256))
        #expect(vacationHashes.contains(TestFixtures.files[0].sha256)) // sunset
        #expect(vacationHashes.contains(TestFixtures.files[1].sha256)) // beach
        #expect(vacationHashes.contains(TestFixtures.files[2].sha256)) // mountain
    }

    @Test func catalogRoundTripWithOptionalFields() throws {
        let spec = TestFixtures.files[0]
        let image = CatalogImage(
            filename: spec.name,
            sha256: spec.sha256,
            sizeBytes: Int64(spec.size),
            par2Filename: spec.par2Name,
            b2FileId: "4_zb2bucket_f1234"
        )

        let album = CatalogAlbum(addedAt: .now, images: [image])
        let catalog = Catalog(version: 2, lastUpdated: .now, years: [
            "2024": CatalogYear(months: ["12": CatalogMonth(days: ["01": CatalogDay(albums: ["Trip": album])])])
        ])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(catalog)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Catalog.self, from: data)

        let decodedImage = decoded.years["2024"]?.months["12"]?.days["01"]?.albums["Trip"]?.images.first
        #expect(decodedImage?.b2FileId == "4_zb2bucket_f1234")
        #expect(decodedImage?.sizeBytes == Int64(spec.size))
        #expect(decodedImage?.par2Filename == spec.par2Name)
    }

    @Test func catalogRoundTripNilB2FileId() throws {
        let spec = TestFixtures.files[1]
        let image = CatalogImage(
            filename: spec.name, sha256: spec.sha256,
            sizeBytes: Int64(spec.size), par2Filename: spec.par2Name
        )

        let album = CatalogAlbum(addedAt: .now, images: [image])
        let catalog = Catalog(version: 1, lastUpdated: .now, years: [
            "2025": CatalogYear(months: ["01": CatalogMonth(days: ["01": CatalogDay(albums: ["Test": album])])])
        ])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(catalog)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Catalog.self, from: data)

        let decodedImage = decoded.years["2025"]?.months["01"]?.days["01"]?.albums["Test"]?.images.first
        #expect(decodedImage?.b2FileId == nil)
    }

    @Test func catalogFileIO() throws {
        let catalog = TestFixtures.catalog()

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try catalog.save(to: tmpURL)

        let loaded = try Catalog.load(from: tmpURL)
        #expect(loaded.version == 1)
        // Verify all 8 images survived the round-trip
        let allImages = loaded.years.values.flatMap { y in
            y.months.values.flatMap { m in
                m.days.values.flatMap { d in
                    d.albums.values.flatMap(\.images)
                }
            }
        }
        #expect(allImages.count == TestFixtures.files.count)
        let allHashes = Set(allImages.map(\.sha256))
        for spec in TestFixtures.files {
            #expect(allHashes.contains(spec.sha256))
        }
    }

    @Test func catalogCodingKeysSnakeCase() throws {
        let spec = TestFixtures.files[0]
        let image = CatalogImage(
            filename: spec.name, sha256: spec.sha256, sizeBytes: Int64(spec.size),
            par2Filename: spec.par2Name, b2FileId: "b2id"
        )
        let album = CatalogAlbum(addedAt: Date(timeIntervalSince1970: 1000), images: [image])
        let catalog = Catalog(version: 1, lastUpdated: Date(timeIntervalSince1970: 2000), years: [
            "2025": CatalogYear(months: ["01": CatalogMonth(days: ["01": CatalogDay(albums: ["A": album])])])
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

@Suite @MainActor
struct HasherServiceTests {
    @Test func sha256MatchesFixtureHashes() async throws {
        let service = HasherService()
        let root = try TestFixtures.materializeVolume(label: "hasher")
        defer { try? FileManager.default.removeItem(at: root) }

        for spec in TestFixtures.files {
            let url = root.appendingPathComponent(spec.albumPath).appendingPathComponent(spec.name)
            let hash = try await service.sha256(of: url)
            #expect(hash == spec.sha256, "Hash mismatch for \(spec.name)")
        }
    }

    @Test func sha256EmptyFile() async throws {
        let service = HasherService()

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-hash-empty-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try Data().write(to: tmpURL)

        let hash = try await service.sha256(of: tmpURL)
        #expect(hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func sha256AndSizeFromFixture() async throws {
        let service = HasherService()
        let spec = TestFixtures.files[3] // forest.heic, 8192 bytes
        let root = try TestFixtures.materializeVolume(label: "hasher-size")
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent(spec.albumPath).appendingPathComponent(spec.name)
        let (hash, size) = try await service.sha256AndSize(of: url)

        #expect(size == Int64(spec.size))
        #expect(hash == spec.sha256)
    }

    @Test func sha256ConsistentBetweenMethods() async throws {
        let service = HasherService()
        let spec = TestFixtures.files[6] // landscape.heic, 10240 bytes
        let root = try TestFixtures.materializeVolume(label: "hasher-consistent")
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent(spec.albumPath).appendingPathComponent(spec.name)
        let hashOnly = try await service.sha256(of: url)
        let (hashAndSize, _) = try await service.sha256AndSize(of: url)

        #expect(hashOnly == hashAndSize)
        #expect(hashOnly == spec.sha256)
    }
}

// MARK: - RedundancyService Tests

@Suite @MainActor
struct RedundancyServiceTests {
    @Test func generateAndVerifyPAR2ForAllFixtures() async throws {
        let service = RedundancyService()
        let root = try TestFixtures.materializeVolume(label: "par2-gen")
        defer { try? FileManager.default.removeItem(at: root) }

        for spec in TestFixtures.files {
            let dir = root.appendingPathComponent(spec.albumPath)
            let fileURL = dir.appendingPathComponent(spec.name)

            let par2URL = try await service.generatePAR2(for: fileURL, outputDirectory: dir)

            #expect(FileManager.default.fileExists(atPath: par2URL.path))
            #expect(par2URL.lastPathComponent == spec.par2Name)

            let isValid = try await service.verify(par2URL: par2URL, originalFileURL: fileURL)
            #expect(isValid, "PAR2 verification failed for \(spec.name)")
        }
    }

    @Test func par2HeaderMagicBytes() async throws {
        let service = RedundancyService()
        let spec = TestFixtures.files[4] // city.heic, 3072 bytes
        let root = try TestFixtures.materializeVolume(label: "par2-magic")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponent(spec.albumPath)
        let fileURL = dir.appendingPathComponent(spec.name)
        let par2URL = try await service.generatePAR2(for: fileURL, outputDirectory: dir)
        let par2Data = try Data(contentsOf: par2URL)

        let magic = String(data: par2Data[0..<4], encoding: .ascii)
        #expect(magic == "PV2R")

        let storedSize = par2Data[4..<12].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        #expect(storedSize == UInt64(spec.size))
    }

    @Test func par2VerifyFailsOnSizeMismatch() async throws {
        let service = RedundancyService()
        let spec = TestFixtures.files[3] // forest.heic, 8192 bytes
        let root = try TestFixtures.materializeVolume(label: "par2-mismatch")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponent(spec.albumPath)
        let fileURL = dir.appendingPathComponent(spec.name)
        let par2URL = try await service.generatePAR2(for: fileURL, outputDirectory: dir)

        // Overwrite with different-sized content
        try Data(repeating: 0x22, count: 4000).write(to: fileURL)

        let isValid = try await service.verify(par2URL: par2URL, originalFileURL: fileURL)
        #expect(!isValid)
    }

    @Test func par2VerifyFailsOnInvalidMagic() async throws {
        let service = RedundancyService()
        let spec = TestFixtures.files[7] // macro.heic, 512 bytes
        let root = try TestFixtures.materializeVolume(label: "par2-badmagic")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponent(spec.albumPath)
        let fileURL = dir.appendingPathComponent(spec.name)

        // Write invalid PAR2 file
        let badPar2URL = dir.appendingPathComponent(spec.par2Name)
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

        // Single byte file — edge case below any fixture size
        let fileURL = tmpDir.appendingPathComponent("tiny.bin")
        try Data([0x42]).write(to: fileURL)

        let par2URL = try await service.generatePAR2(for: fileURL, outputDirectory: tmpDir)
        let isValid = try await service.verify(par2URL: par2URL, originalFileURL: fileURL)
        #expect(isValid)
    }

    @Test func par2CorruptAndRepairRoundTrip() async throws {
        let service = RedundancyService()
        let hasher = HasherService()

        // Use forest.heic (8192 bytes) — exactly 2 blocks at blockSize=4096
        let spec = TestFixtures.files[3]
        let root = try TestFixtures.materializeVolume(label: "par2-repair")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponent(spec.albumPath)
        let fileURL = dir.appendingPathComponent(spec.name)
        let originalData = TestFixtures.content(for: spec)

        let par2URL = try await service.generatePAR2(for: fileURL, outputDirectory: dir)

        // Corrupt bytes in the first block
        var corruptedData = originalData
        for i in 100..<200 { corruptedData[i] = 0xFF }
        try corruptedData.write(to: fileURL)

        let corruptedHash = try await hasher.sha256(of: fileURL)
        #expect(corruptedHash != spec.sha256)

        let repairedData = try await service.repair(par2URL: par2URL, corruptedFileURL: fileURL)
        #expect(repairedData != nil)

        let repairedURL = dir.appendingPathComponent("repaired.bin")
        try repairedData!.write(to: repairedURL)
        let repairedHash = try await hasher.sha256(of: repairedURL)

        #expect(repairedHash == spec.sha256)
        #expect(repairedData! == originalData)
    }

    @Test func par2CorruptAndRepairLastBlock() async throws {
        let service = RedundancyService()
        let hasher = HasherService()

        // Use portrait.heic (5120 bytes) — partial last block (5120/4096 = 1 full + 1 partial)
        let spec = TestFixtures.files[5]
        let root = try TestFixtures.materializeVolume(label: "par2-repair-last")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponent(spec.albumPath)
        let fileURL = dir.appendingPathComponent(spec.name)

        let par2URL = try await service.generatePAR2(for: fileURL, outputDirectory: dir)

        // Corrupt bytes in the last (partial) block
        var corrupted = TestFixtures.content(for: spec)
        for i in 4500..<4550 { corrupted[i] = 0x00 }
        try corrupted.write(to: fileURL)

        let repairedData = try await service.repair(par2URL: par2URL, corruptedFileURL: fileURL)
        #expect(repairedData != nil)

        let repairedURL = dir.appendingPathComponent("repaired.bin")
        try repairedData!.write(to: repairedURL)
        let repairedHash = try await hasher.sha256(of: repairedURL)

        #expect(repairedHash == spec.sha256)
    }

    @Test func par2LargerThanBlockSize() async throws {
        let service = RedundancyService()

        // Use landscape.heic (10240 bytes) — multi-block: ceil(10240/4096)=3 blocks
        let spec = TestFixtures.files[6]
        let root = try TestFixtures.materializeVolume(label: "par2-large")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponent(spec.albumPath)
        let fileURL = dir.appendingPathComponent(spec.name)

        let par2URL = try await service.generatePAR2(for: fileURL, outputDirectory: dir)
        let isValid = try await service.verify(par2URL: par2URL, originalFileURL: fileURL)
        #expect(isValid)

        let par2Data = try Data(contentsOf: par2URL)
        let storedBlockSize = par2Data[12..<16].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let blockCount = par2Data[16..<20].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let recoveryCount = par2Data[20..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(storedBlockSize == 4096)
        #expect(blockCount == 3) // ceil(10240/4096) = 2.5 → 3
        #expect(recoveryCount >= 2)
    }
}

// MARK: - PerceptualHash Tests

@Suite @MainActor
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
    // Fixture constants (inlined to avoid @MainActor requirement from TestFixtures)
    private static let fixtureSpecs: [(sha256: String, name: String, size: Int, albumPath: String)] = [
        ("15c7be47d93f2f2786bda2b188de3c42c35432ce7ce48b15a8b3d56beacdf896", "sunset.heic", 1024, "2025/07/15/Vacation"),
        ("925dd3eef2e812a9cdbebc55d0a757d69cc3747e0d0cd68a078ff66b1c2c7037", "beach.heic", 2048, "2025/07/15/Vacation"),
        ("b46186d5652517a5fc887a4cc4a31a6f65586aaa6751cc48fc05f6485ba23a15", "mountain.heic", 4096, "2025/07/15/Vacation"),
    ]

    private static func materializeFixtures() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-integrity-\(UUID().uuidString)")
        for spec in fixtureSpecs {
            let dir = root.appendingPathComponent(spec.albumPath, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Same deterministic content formula as TestFixtures
            let primes = [(37, 13), (53, 7), (97, 3)]
            let idx = fixtureSpecs.firstIndex(where: { $0.sha256 == spec.sha256 })!
            let (prime, offset) = primes[idx]
            let data = Data((0..<spec.size).map { UInt8(($0 * prime + offset) % 256) })
            try data.write(to: dir.appendingPathComponent(spec.name))
        }
        return root
    }

    @Test func verifyPassesForFixtureFiles() async throws {
        let integrity = IntegrityService()
        let root = try Self.materializeFixtures()
        defer { try? FileManager.default.removeItem(at: root) }

        let images = Self.fixtureSpecs.map { ImageRecord(sha256: $0.sha256, filename: $0.name, sizeBytes: Int64($0.size)) }
        let urlMap = Dictionary(uniqueKeysWithValues: Self.fixtureSpecs.map { spec in
            (spec.sha256, root.appendingPathComponent(spec.albumPath).appendingPathComponent(spec.name))
        })

        let results = await integrity.verify(
            images: images,
            sourceResolver: { urlMap[$0.sha256] }
        )

        #expect(results.count == 3)
        for result in results {
            #expect(result.passed == true)
        }
    }

    @Test func verifyFailsForHashMismatch() async throws {
        let integrity = IntegrityService()
        let root = try Self.materializeFixtures()
        defer { try? FileManager.default.removeItem(at: root) }

        let spec = Self.fixtureSpecs[0]
        let url = root.appendingPathComponent(spec.albumPath).appendingPathComponent(spec.name)

        let image = ImageRecord(sha256: "0000000000000000000000000000000000000000000000000000000000000000", filename: spec.name, sizeBytes: Int64(spec.size))

        let results = await integrity.verify(
            images: [image],
            sourceResolver: { _ in url }
        )

        #expect(results.count == 1)
        #expect(results[0].passed == false)
        #expect(results[0].actualHash == spec.sha256)
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
        for i in 0..<8 {
            images.append(ImageRecord(sha256: "hash\(i)", filename: "file\(i).bin", sizeBytes: 100))
        }

        let results = await integrity.verify(
            images: images,
            sourceResolver: { _ in nil },
            batchSize: 3
        )

        #expect(results.count == 3)
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
        let specs = TestFixtures.files(inAlbum: "Vacation")

        let album = AlbumRecord(name: "Vacation", year: "2025", month: "07", day: "15")
        context.insert(album)

        for spec in specs {
            let image = ImageRecord(sha256: spec.sha256, filename: spec.name, sizeBytes: Int64(spec.size))
            image.album = album
            context.insert(image)
        }

        try context.save()

        #expect(album.images.count == specs.count) // 3 Vacation images
        #expect(album.images.allSatisfy { $0.album?.name == "Vacation" })
    }

    @Test func imageRecordDefaults() throws {
        let spec = TestFixtures.files[0]
        let image = ImageRecord(sha256: spec.sha256, filename: spec.name, sizeBytes: Int64(spec.size))

        #expect(image.thumbnailState == .pending)
        #expect(image.perceptualHash == nil)
        #expect(image.b2FileId == nil)
        #expect(image.lastVerifiedAt == nil)
        #expect(image.storageLocations.isEmpty)
        #expect(image.par2Filename == "")
    }

    @Test func storageLocationCodable() throws {
        let spec = TestFixtures.files[0]
        let location = StorageLocation(volumeID: "vol-123", relativePath: "\(spec.albumPath)/\(spec.name)")
        let data = try JSONEncoder().encode(location)
        let decoded = try JSONDecoder().decode(StorageLocation.self, from: data)

        #expect(decoded.volumeID == "vol-123")
        #expect(decoded.relativePath == "\(spec.albumPath)/\(spec.name)")
    }

    @Test func thumbnailStateCodable() throws {
        for state in [ThumbnailState.pending, .generated, .failed] {
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(ThumbnailState.self, from: data)
            #expect(decoded == state)
        }
    }
}

// MARK: - Reconciliation B2 Diff Tests

@Suite @MainActor
struct ReconciliationDiffTests {
    @Test func diffB2AllMatched() {
        let specs = Array(TestFixtures.files.prefix(3))
        let snapshots = specs.enumerated().map { i, spec in
            ImageSnapshot(sha256: spec.sha256, filename: spec.name, b2FileId: "b2-\(i)", storageLocations: [], albumPath: spec.albumPath)
        }
        let b2Files = specs.enumerated().map { i, spec in
            B2FileListing(fileId: "b2-\(i)", fileName: "\(spec.albumPath)/\(spec.name)", contentLength: Int64(spec.size))
        }

        let result = ReconciliationService.diffB2(snapshots: snapshots, b2Files: b2Files)
        #expect(result.isEmpty)
    }

    @Test func diffB2DetectsDanglingB2FileId() {
        let spec = TestFixtures.files[0]
        let snapshots = [
            ImageSnapshot(sha256: spec.sha256, filename: spec.name, b2FileId: "b2-gone", storageLocations: [], albumPath: spec.albumPath),
        ]
        let b2Files: [B2FileListing] = []

        let result = ReconciliationService.diffB2(snapshots: snapshots, b2Files: b2Files)
        #expect(result.count == 1)
        if case .danglingB2FileId = result.first?.kind {} else {
            Issue.record("Expected .danglingB2FileId, got \(String(describing: result.first?.kind))")
        }
    }

    @Test func diffB2DetectsOrphanInB2() {
        let spec = TestFixtures.files[1]
        let snapshots: [ImageSnapshot] = []
        let b2Files = [
            B2FileListing(fileId: "b2-orphan", fileName: "\(spec.albumPath)/\(spec.name)", contentLength: Int64(spec.size)),
        ]

        let result = ReconciliationService.diffB2(snapshots: snapshots, b2Files: b2Files)
        #expect(result.count == 1)
        if case .orphanInB2(let fid, _) = result.first?.kind {
            #expect(fid == "b2-orphan")
        } else {
            Issue.record("Expected .orphanInB2")
        }
    }

    @Test func diffB2SkipsPAR2Files() {
        let spec = TestFixtures.files[0]
        let snapshots: [ImageSnapshot] = []
        let b2Files = [
            B2FileListing(fileId: "b2-par2", fileName: "\(spec.albumPath)/\(spec.par2Name)", contentLength: 50),
        ]

        let result = ReconciliationService.diffB2(snapshots: snapshots, b2Files: b2Files)
        #expect(result.isEmpty)
    }

    @Test func diffB2MixedScenario() {
        let specs = Array(TestFixtures.files.prefix(3))
        let snapshots = [
            ImageSnapshot(sha256: specs[0].sha256, filename: specs[0].name, b2FileId: "b2-ok", storageLocations: [], albumPath: specs[0].albumPath),
            ImageSnapshot(sha256: specs[1].sha256, filename: specs[1].name, b2FileId: "b2-missing", storageLocations: [], albumPath: specs[1].albumPath),
            ImageSnapshot(sha256: specs[2].sha256, filename: specs[2].name, b2FileId: nil, storageLocations: [], albumPath: specs[2].albumPath),
        ]
        let b2Files = [
            B2FileListing(fileId: "b2-ok", fileName: "\(specs[0].albumPath)/\(specs[0].name)", contentLength: Int64(specs[0].size)),
            B2FileListing(fileId: "b2-extra", fileName: "\(specs[0].albumPath)/extra.heic", contentLength: 200),
        ]

        let result = ReconciliationService.diffB2(snapshots: snapshots, b2Files: b2Files)

        let danglingCount = result.filter { if case .danglingB2FileId = $0.kind { return true }; return false }.count
        let orphanCount = result.filter { if case .orphanInB2 = $0.kind { return true }; return false }.count

        #expect(danglingCount == 1)
        #expect(orphanCount == 1)
    }
}

// MARK: - Volume Scan Tests

@Suite
@MainActor
struct VolumeScanTests {
    @Test func scanDetectsDanglingLocation() async {
        let service = ReconciliationService()
        let progress = ReconciliationProgress()
        let spec = TestFixtures.files[0]

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-vol-scan-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Snapshot references a file on this volume, but the file doesn't exist
        let snapshots = [
            ImageSnapshot(
                sha256: spec.sha256,
                filename: spec.name,
                b2FileId: nil,
                storageLocations: [StorageLocation(volumeID: "vol-1", relativePath: "\(spec.albumPath)/\(spec.name)")],
                albumPath: spec.albumPath
            ),
        ]
        let volumes = [VolumeSnapshot(volumeID: "vol-1", label: "TestVol", mountURL: tmpDir)]

        let report = await service.reconcile(snapshots: snapshots, volumes: volumes, b2Credentials: nil, progress: progress)

        let dangling = report.discrepancies.filter { if case .danglingLocation = $0.kind { return true }; return false }
        #expect(dangling.count == 1)
        #expect(dangling.first?.sha256 == spec.sha256)
    }

    @Test func scanDetectsOrphanOnVolume() async throws {
        let service = ReconciliationService()
        let progress = ReconciliationProgress()

        // Materialize all fixture files, but provide NO snapshots — all files are orphans
        let root = try TestFixtures.materializeVolume(label: "vol-orphan")
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshots: [ImageSnapshot] = []
        let volumes = [VolumeSnapshot(volumeID: "vol-1", label: "TestVol", mountURL: root)]

        let report = await service.reconcile(snapshots: snapshots, volumes: volumes, b2Credentials: nil, progress: progress)

        let orphans = report.discrepancies.filter { if case .orphanOnVolume = $0.kind { return true }; return false }
        #expect(orphans.count == TestFixtures.files.count) // All 8 are orphans
    }

    @Test func scanPassesWhenFileExists() async throws {
        let service = ReconciliationService()
        let progress = ReconciliationProgress()

        let root = try TestFixtures.materializeVolume(label: "vol-ok")
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshots = TestFixtures.imageSnapshots(onVolume: "vol-1")
        let volumes = [VolumeSnapshot(volumeID: "vol-1", label: "TestVol", mountURL: root)]

        let report = await service.reconcile(snapshots: snapshots, volumes: volumes, b2Credentials: nil, progress: progress)
        // No discrepancies when all files exist and match snapshots
        let dangling = report.discrepancies.filter { if case .danglingLocation = $0.kind { return true }; return false }
        #expect(dangling.isEmpty)
    }

    @Test func scanIgnoresVolumeNotInSnapshots() async {
        let service = ReconciliationService()
        let progress = ReconciliationProgress()
        let spec = TestFixtures.files[0]

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-vol-ignore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Snapshot references vol-2 but we only provide vol-1
        let snapshots = [
            ImageSnapshot(
                sha256: spec.sha256,
                filename: spec.name,
                b2FileId: nil,
                storageLocations: [StorageLocation(volumeID: "vol-2", relativePath: "\(spec.albumPath)/\(spec.name)")],
                albumPath: spec.albumPath
            ),
        ]
        let volumes = [VolumeSnapshot(volumeID: "vol-1", label: "TestVol", mountURL: tmpDir)]

        let report = await service.reconcile(snapshots: snapshots, volumes: volumes, b2Credentials: nil, progress: progress)

        let dangling = report.discrepancies.filter { if case .danglingLocation = $0.kind { return true }; return false }
        #expect(dangling.isEmpty)
    }
}

// MARK: - Volume Sync (Add Second Storage) Tests

@Suite @MainActor
struct VolumeSyncToNewVolumeTests {
    /// End-to-end: materialize all 8 fixtures on volume A, sync to volume B, verify hashes.
    @Test func syncAllFixturesFromVolumeAToVolumeB() async throws {
        let hasher = HasherService()
        let volumeService = VolumeService()
        let fm = FileManager.default

        let volA = try TestFixtures.materializeVolume(label: "syncA")
        let volB = fm.temporaryDirectory.appendingPathComponent("lumivault-syncB-\(UUID().uuidString)")
        try fm.createDirectory(at: volB, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: volA); try? fm.removeItem(at: volB) }

        let inputs = TestFixtures.syncInputs(onVolume: "vol-a")

        let (result, newLocations) = await volumeService.syncToVolume(
            images: inputs,
            targetVolumeURL: volB,
            targetVolumeID: "vol-b",
            sourceVolumes: [("vol-a", volA)]
        )

        #expect(result.copied == TestFixtures.files.count)
        #expect(result.deduplicated == 0)
        #expect(result.skipped == 0)
        #expect(result.errors.isEmpty)
        #expect(newLocations.count == TestFixtures.files.count)

        // Verify every file on volume B has the correct hash
        for spec in TestFixtures.files {
            let destURL = volB.appendingPathComponent(spec.albumPath).appendingPathComponent(spec.name)
            #expect(fm.fileExists(atPath: destURL.path), "\(spec.name) missing on vol B")
            let destHash = try await hasher.sha256(of: destURL)
            #expect(destHash == spec.sha256, "Hash mismatch for \(spec.name)")
        }
    }

    /// Dedup: pre-place all fixtures on both volumes, sync should detect all as deduplicated.
    @Test func syncDeduplicatesExistingFilesByHash() async throws {
        let volumeService = VolumeService()

        let volA = try TestFixtures.materializeVolume(label: "dedupA")
        let volB = try TestFixtures.materializeVolume(label: "dedupB")
        defer { try? FileManager.default.removeItem(at: volA); try? FileManager.default.removeItem(at: volB) }

        let inputs = TestFixtures.syncInputs(onVolume: "vol-a")

        let (result, newLocations) = await volumeService.syncToVolume(
            images: inputs,
            targetVolumeURL: volB,
            targetVolumeID: "vol-b",
            sourceVolumes: [("vol-a", volA)]
        )

        #expect(result.copied == 0)
        #expect(result.deduplicated == TestFixtures.files.count)
        #expect(result.skipped == 0)
        #expect(newLocations.count == TestFixtures.files.count)

        // Every new location should point to vol-b
        for loc in newLocations {
            #expect(loc.location.volumeID == "vol-b")
        }
    }

    /// Hash mismatch: place a different file with the same name on the target.
    @Test func syncDetectsHashMismatchOnTarget() async throws {
        let volumeService = VolumeService()
        let fm = FileManager.default
        let spec = TestFixtures.files[0]

        let volA = try TestFixtures.materializeVolume(label: "mismatchA")
        let volB = fm.temporaryDirectory.appendingPathComponent("lumivault-mismatchB-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: volA); try? fm.removeItem(at: volB) }

        // Place corrupted file on vol B
        let dirB = volB.appendingPathComponent(spec.albumPath)
        try fm.createDirectory(at: dirB, withIntermediateDirectories: true)
        try Data("corrupted content".utf8).write(to: dirB.appendingPathComponent(spec.name))

        let inputs = [TestFixtures.syncInputs(onVolume: "vol-a")[0]]

        let (result, newLocations) = await volumeService.syncToVolume(
            images: inputs,
            targetVolumeURL: volB,
            targetVolumeID: "vol-b",
            sourceVolumes: [("vol-a", volA)]
        )

        #expect(result.copied == 0)
        #expect(result.deduplicated == 0)
        #expect(result.errors.count == 1)
        #expect(newLocations.isEmpty)
    }

    /// No source available — should skip all.
    @Test func syncSkipsWhenNoSourceAvailable() async {
        let volumeService = VolumeService()
        let fm = FileManager.default

        let volB = fm.temporaryDirectory.appendingPathComponent("lumivault-nosrc-\(UUID().uuidString)")
        try? fm.createDirectory(at: volB, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: volB) }

        let inputs = TestFixtures.syncInputs(onVolume: "vol-a")

        let (result, newLocations) = await volumeService.syncToVolume(
            images: inputs,
            targetVolumeURL: volB,
            targetVolumeID: "vol-b",
            sourceVolumes: [] // No sources
        )

        #expect(result.copied == 0)
        #expect(result.deduplicated == 0)
        #expect(result.skipped == TestFixtures.files.count)
        #expect(newLocations.isEmpty)
    }

    /// PAR2 companions should also be copied during sync.
    @Test func syncCopiesPAR2CompanionFiles() async throws {
        let volumeService = VolumeService()
        let fm = FileManager.default

        let volA = try await TestFixtures.materializeVolumeWithPAR2(label: "par2syncA")
        let volB = fm.temporaryDirectory.appendingPathComponent("lumivault-par2syncB-\(UUID().uuidString)")
        try fm.createDirectory(at: volB, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: volA); try? fm.removeItem(at: volB) }

        let inputs = TestFixtures.syncInputs(onVolume: "vol-a")

        let (result, _) = await volumeService.syncToVolume(
            images: inputs,
            targetVolumeURL: volB,
            targetVolumeID: "vol-b",
            sourceVolumes: [("vol-a", volA)]
        )

        #expect(result.copied == TestFixtures.files.count)

        // Verify both image and PAR2 exist on volume B for every fixture
        for spec in TestFixtures.files {
            let destDir = volB.appendingPathComponent(spec.albumPath)
            #expect(fm.fileExists(atPath: destDir.appendingPathComponent(spec.name).path), "\(spec.name) missing")
            #expect(fm.fileExists(atPath: destDir.appendingPathComponent(spec.par2Name).path), "\(spec.par2Name) missing")
        }
    }
}

// MARK: - Catalog Removal Tests

@Suite @MainActor
struct CatalogRemovalTests {
    @Test func removeAlbumFromCatalog() async {
        let service = CatalogService()

        // Add images to two albums
        for spec in TestFixtures.files(inAlbum: "Vacation") {
            let image = CatalogImage(filename: spec.name, sha256: spec.sha256, sizeBytes: Int64(spec.size), par2Filename: spec.par2Name)
            await service.addImage(image, toAlbum: "Vacation", year: "2025", month: "07", day: "15")
        }
        for spec in TestFixtures.files(inAlbum: "Nature") {
            let image = CatalogImage(filename: spec.name, sha256: spec.sha256, sizeBytes: Int64(spec.size), par2Filename: spec.par2Name)
            await service.addImage(image, toAlbum: "Nature", year: "2025", month: "07", day: "15")
        }

        // Remove Vacation album
        await service.removeAlbum(name: "Vacation", year: "2025", month: "07", day: "15")

        let catalog = await service.currentCatalog()
        let dayAlbums = catalog.years["2025"]?.months["07"]?.days["15"]?.albums
        #expect(dayAlbums?["Vacation"] == nil)
        #expect(dayAlbums?["Nature"] != nil)
        #expect(dayAlbums?["Nature"]?.images.count == TestFixtures.files(inAlbum: "Nature").count)
    }

    @Test func removeAlbumPrunesEmptyContainers() async {
        let service = CatalogService()
        let spec = TestFixtures.files[0]

        let image = CatalogImage(filename: spec.name, sha256: spec.sha256, sizeBytes: Int64(spec.size), par2Filename: spec.par2Name)
        await service.addImage(image, toAlbum: "Solo", year: "2024", month: "12", day: "25")

        await service.removeAlbum(name: "Solo", year: "2024", month: "12", day: "25")

        let catalog = await service.currentCatalog()
        // Entire year should be pruned since it was the only album
        #expect(catalog.years["2024"] == nil)
    }

    @Test func removeImageFromCatalog() async {
        let service = CatalogService()
        let specs = TestFixtures.files(inAlbum: "Vacation")

        for spec in specs {
            let image = CatalogImage(filename: spec.name, sha256: spec.sha256, sizeBytes: Int64(spec.size), par2Filename: spec.par2Name)
            await service.addImage(image, toAlbum: "Vacation", year: "2025", month: "07", day: "15")
        }

        // Remove one image
        let removed = specs[0]
        await service.removeImage(sha256: removed.sha256, fromAlbum: "Vacation", year: "2025", month: "07", day: "15")

        let catalog = await service.currentCatalog()
        let images = catalog.years["2025"]?.months["07"]?.days["15"]?.albums["Vacation"]?.images ?? []
        #expect(images.count == specs.count - 1)
        #expect(!images.contains { $0.sha256 == removed.sha256 })
    }
}

// MARK: - Deletion Service Tests

@Suite @MainActor
struct DeletionServiceTests {
    @Test func deleteRemovesFilesFromVolume() async throws {
        let fm = FileManager.default
        let root = try TestFixtures.materializeVolume(label: "deletion")
        defer { try? fm.removeItem(at: root) }

        let spec = TestFixtures.files[0]
        let progress = DeletionProgress()

        let input = DeletionService.ImageDeletionInput(
            sha256: spec.sha256,
            filename: spec.name,
            par2Filename: "",
            b2FileId: nil,
            storageLocations: [StorageLocation(volumeID: "vol-1", relativePath: "\(spec.albumPath)/\(spec.name)")],
            albumPath: spec.albumPath
        )

        let service = DeletionService()
        let result = await service.deleteImageFiles(
            images: [input],
            mountedVolumes: [("vol-1", root)],
            b2Credentials: nil,
            progress: progress
        )

        #expect(result.volumeFilesRemoved == 1)
        #expect(result.errors.isEmpty)

        let filePath = root.appendingPathComponent(spec.albumPath).appendingPathComponent(spec.name)
        #expect(!fm.fileExists(atPath: filePath.path))
    }

    @Test func deleteRemovesPAR2Companion() async throws {
        let fm = FileManager.default
        let root = try await TestFixtures.materializeVolumeWithPAR2(label: "deletion-par2")
        defer { try? fm.removeItem(at: root) }

        let spec = TestFixtures.files[0]
        let progress = DeletionProgress()

        let input = DeletionService.ImageDeletionInput(
            sha256: spec.sha256,
            filename: spec.name,
            par2Filename: spec.par2Name,
            b2FileId: nil,
            storageLocations: [StorageLocation(volumeID: "vol-1", relativePath: "\(spec.albumPath)/\(spec.name)")],
            albumPath: spec.albumPath
        )

        let service = DeletionService()
        _ = await service.deleteImageFiles(
            images: [input],
            mountedVolumes: [("vol-1", root)],
            b2Credentials: nil,
            progress: progress
        )

        let par2Path = root.appendingPathComponent(spec.albumPath).appendingPathComponent(spec.par2Name)
        #expect(!fm.fileExists(atPath: par2Path.path))
    }

    @Test func deleteSkipsUnmountedVolumes() async throws {
        let fm = FileManager.default
        let root = try TestFixtures.materializeVolume(label: "deletion-skip")
        defer { try? fm.removeItem(at: root) }

        let spec = TestFixtures.files[0]
        let progress = DeletionProgress()

        let input = DeletionService.ImageDeletionInput(
            sha256: spec.sha256,
            filename: spec.name,
            par2Filename: "",
            b2FileId: nil,
            storageLocations: [StorageLocation(volumeID: "vol-missing", relativePath: "\(spec.albumPath)/\(spec.name)")],
            albumPath: spec.albumPath
        )

        let service = DeletionService()
        let result = await service.deleteImageFiles(
            images: [input],
            mountedVolumes: [("vol-1", root)], // vol-missing is not here
            b2Credentials: nil,
            progress: progress
        )

        #expect(result.volumeFilesRemoved == 0)
        #expect(result.errors.isEmpty)

        // File should still exist (not deleted from vol-1)
        let filePath = root.appendingPathComponent(spec.albumPath).appendingPathComponent(spec.name)
        #expect(fm.fileExists(atPath: filePath.path))
    }

    @Test func deleteAllFixtureFilesFromVolume() async throws {
        let fm = FileManager.default
        let root = try TestFixtures.materializeVolume(label: "deletion-all")
        defer { try? fm.removeItem(at: root) }

        let progress = DeletionProgress()
        let inputs = TestFixtures.files.map { spec in
            DeletionService.ImageDeletionInput(
                sha256: spec.sha256,
                filename: spec.name,
                par2Filename: "",
                b2FileId: nil,
                storageLocations: [StorageLocation(volumeID: "vol-1", relativePath: "\(spec.albumPath)/\(spec.name)")],
                albumPath: spec.albumPath
            )
        }

        let service = DeletionService()
        let result = await service.deleteImageFiles(
            images: inputs,
            mountedVolumes: [("vol-1", root)],
            b2Credentials: nil,
            progress: progress
        )

        #expect(result.volumeFilesRemoved == TestFixtures.files.count)
        #expect(result.errors.isEmpty)

        // Verify no fixture files remain
        for spec in TestFixtures.files {
            let path = root.appendingPathComponent(spec.albumPath).appendingPathComponent(spec.name)
            #expect(!fm.fileExists(atPath: path.path), "\(spec.name) should be deleted")
        }
    }
}
