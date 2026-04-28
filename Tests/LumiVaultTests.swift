import Testing
import Foundation
import SwiftData
import CryptoKit
import AppKit
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

            let par2URL = try service.generatePAR2(for: fileURL, outputDirectory: dir)

            #expect(FileManager.default.fileExists(atPath: par2URL.path))
            #expect(par2URL.lastPathComponent == spec.par2Name)

            let isValid = try service.verify(par2URL: par2URL, originalFileURL: fileURL)
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
        let par2URL = try service.generatePAR2(for: fileURL, outputDirectory: dir)
        let par2Data = try Data(contentsOf: par2URL)

        // PAR2 2.0 magic: "PAR2\0PKT"
        let magic = Array(par2Data[0..<8])
        #expect(magic == [0x50, 0x41, 0x52, 0x32, 0x00, 0x50, 0x4B, 0x54])
    }

    @Test func par2SplitFileFormat() async throws {
        let service = RedundancyService()
        let spec = TestFixtures.files[4] // city.heic, 3072 bytes
        let root = try TestFixtures.materializeVolume(label: "par2-split")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponent(spec.albumPath)
        let fileURL = dir.appendingPathComponent(spec.name)
        let par2URL = try service.generatePAR2(for: fileURL, outputDirectory: dir)

        // Index file should exist
        #expect(FileManager.default.fileExists(atPath: par2URL.path))
        #expect(par2URL.lastPathComponent == "\(spec.name).par2")

        // At least one vol file should exist
        let companions = RedundancyService.companionFiles(forIndex: par2URL.lastPathComponent, in: dir)
        #expect(companions.count >= 2) // index + at least one vol
        let volFiles = companions.filter { $0.lastPathComponent.contains(".vol") }
        #expect(!volFiles.isEmpty)
    }

    @Test func par2VerifyFailsOnSizeMismatch() async throws {
        let service = RedundancyService()
        let spec = TestFixtures.files[3] // forest.heic, 8192 bytes
        let root = try TestFixtures.materializeVolume(label: "par2-mismatch")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponent(spec.albumPath)
        let fileURL = dir.appendingPathComponent(spec.name)
        let par2URL = try service.generatePAR2(for: fileURL, outputDirectory: dir)

        // Overwrite with different-sized content
        try Data(repeating: 0x22, count: 4000).write(to: fileURL)

        let isValid = try service.verify(par2URL: par2URL, originalFileURL: fileURL)
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

        let isValid = try service.verify(par2URL: badPar2URL, originalFileURL: fileURL)
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

        let par2URL = try service.generatePAR2(for: fileURL, outputDirectory: tmpDir)
        let isValid = try service.verify(par2URL: par2URL, originalFileURL: fileURL)
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

        let par2URL = try service.generatePAR2(for: fileURL, outputDirectory: dir)

        // Corrupt bytes in the first block
        var corruptedData = originalData
        for i in 100..<200 { corruptedData[i] = 0xFF }
        try corruptedData.write(to: fileURL)

        let corruptedHash = try await hasher.sha256(of: fileURL)
        #expect(corruptedHash != spec.sha256)

        let repairedData = try service.repair(par2URL: par2URL, corruptedFileURL: fileURL)
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

        let par2URL = try service.generatePAR2(for: fileURL, outputDirectory: dir)

        // Corrupt bytes in the last (partial) block
        var corrupted = TestFixtures.content(for: spec)
        for i in 4500..<4550 { corrupted[i] = 0x00 }
        try corrupted.write(to: fileURL)

        let repairedData = try service.repair(par2URL: par2URL, corruptedFileURL: fileURL)
        #expect(repairedData != nil, "PAR2 repair returned nil for partial last block")
        guard let repairedData else { return }

        let repairedURL = dir.appendingPathComponent("repaired.bin")
        try repairedData.write(to: repairedURL)
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

        let par2URL = try service.generatePAR2(for: fileURL, outputDirectory: dir)
        let isValid = try service.verify(par2URL: par2URL, originalFileURL: fileURL)
        #expect(isValid)

        // Verify vol file contains recovery slices
        let companions = RedundancyService.companionFiles(forIndex: par2URL.lastPathComponent, in: dir)
        let volFiles = companions.filter { $0.lastPathComponent.contains(".vol") }
        #expect(!volFiles.isEmpty)
        // Vol file should be larger than index (it contains recovery data)
        let indexSize = try Data(contentsOf: par2URL).count
        let volSize = try Data(contentsOf: volFiles[0]).count
        #expect(volSize > indexSize)
    }

    @Test func par2cmdlineInteroperabilityVerify() async throws {
        // Skip if par2cmdline is not installed
        let par2Path = "/opt/homebrew/bin/par2"
        guard FileManager.default.fileExists(atPath: par2Path) else { return }

        let service = RedundancyService()
        let spec = TestFixtures.files[3] // forest.heic, 8192 bytes
        let root = try TestFixtures.materializeVolume(label: "par2-interop")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponent(spec.albumPath)
        let fileURL = dir.appendingPathComponent(spec.name)

        let par2URL = try service.generatePAR2(for: fileURL, outputDirectory: dir)

        // Run par2cmdline verify
        let process = Process()
        process.executableURL = URL(fileURLWithPath: par2Path)
        process.arguments = ["verify", par2URL.path]
        process.currentDirectoryURL = dir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "par2cmdline verify failed")
    }

    @Test func par2cmdlineInteroperabilityRepair() async throws {
        // Skip if par2cmdline is not installed
        let par2Path = "/opt/homebrew/bin/par2"
        guard FileManager.default.fileExists(atPath: par2Path) else { return }

        let service = RedundancyService()

        // Use random-ish data with distinct blocks (repeating patterns confuse par2cmdline's
        // block scanner when blocks have identical checksums)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var originalBytes = [UInt8](repeating: 0, count: 16384)  // 4 blocks × 4096
        for i in 0..<originalBytes.count {
            let blockSeed = i / 4096
            let val = (i &* 97 &+ blockSeed &* 13 &+ 37) & 0xFF
            originalBytes[i] = UInt8(val)
        }
        let originalData = Data(originalBytes)
        let dir = tmpDir
        let fileURL = dir.appendingPathComponent("testfile.bin")
        try originalData.write(to: fileURL)

        let par2URL = try service.generatePAR2(for: fileURL, outputDirectory: dir)

        // Corrupt the file
        var corrupted = originalData
        for i in 100..<200 { corrupted[i] = 0xFF }
        try corrupted.write(to: fileURL)

        // Run par2cmdline repair
        let process = Process()
        process.executableURL = URL(fileURLWithPath: par2Path)
        process.arguments = ["repair", par2URL.path]
        process.currentDirectoryURL = dir
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "par2cmdline repair failed")

        // Verify repaired file matches original
        let repairedData = try Data(contentsOf: fileURL)
        #expect(repairedData == originalData)
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
            ImageSnapshot(sha256: spec.sha256, filename: spec.name, par2Filename: "", b2FileId: "b2-\(i)", storageLocations: [], albumPath: spec.albumPath)
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
            ImageSnapshot(sha256: spec.sha256, filename: spec.name, par2Filename: "", b2FileId: "b2-gone", storageLocations: [], albumPath: spec.albumPath),
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
            ImageSnapshot(sha256: specs[0].sha256, filename: specs[0].name, par2Filename: "", b2FileId: "b2-ok", storageLocations: [], albumPath: specs[0].albumPath),
            ImageSnapshot(sha256: specs[1].sha256, filename: specs[1].name, par2Filename: "", b2FileId: "b2-missing", storageLocations: [], albumPath: specs[1].albumPath),
            ImageSnapshot(sha256: specs[2].sha256, filename: specs[2].name, par2Filename: "", b2FileId: nil, storageLocations: [], albumPath: specs[2].albumPath),
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
                par2Filename: "",
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
                par2Filename: "",
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

        let vacationFiles = TestFixtures.files(inAlbum: "Vacation")
        let progress = DeletionProgress()

        let inputs = vacationFiles.map { spec in
            DeletionService.ImageDeletionInput(
                sha256: spec.sha256,
                filename: spec.name,
                par2Filename: "",
                b2FileId: nil,
                storageLocations: [],
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

        #expect(result.volumeFilesRemoved == vacationFiles.count)
        #expect(result.errors.isEmpty)

        // Album directory should be gone
        let albumDir = root.appendingPathComponent(vacationFiles[0].albumPath)
        #expect(!fm.fileExists(atPath: albumDir.path))
    }

    @Test func deleteRemovesPAR2Companion() async throws {
        let fm = FileManager.default
        let root = try TestFixtures.materializeVolumeWithPAR2(label: "deletion-par2")
        defer { try? fm.removeItem(at: root) }

        let vacationFiles = TestFixtures.files(inAlbum: "Vacation")
        let progress = DeletionProgress()

        let inputs = vacationFiles.map { spec in
            DeletionService.ImageDeletionInput(
                sha256: spec.sha256,
                filename: spec.name,
                par2Filename: spec.par2Name,
                b2FileId: nil,
                storageLocations: [],
                albumPath: spec.albumPath
            )
        }

        let service = DeletionService()
        _ = await service.deleteImageFiles(
            images: inputs,
            mountedVolumes: [("vol-1", root)],
            b2Credentials: nil,
            progress: progress
        )

        // Entire album directory (including PAR2 files) should be gone
        let albumDir = root.appendingPathComponent(vacationFiles[0].albumPath)
        #expect(!fm.fileExists(atPath: albumDir.path))
    }

    @Test func deleteSkipsNonExistentAlbumDir() async throws {
        let fm = FileManager.default
        let root = try TestFixtures.materializeVolume(label: "deletion-skip")
        defer { try? fm.removeItem(at: root) }

        let progress = DeletionProgress()

        // Use a non-existent album path — no directory to remove
        let input = DeletionService.ImageDeletionInput(
            sha256: "fake",
            filename: "fake.heic",
            par2Filename: "",
            b2FileId: nil,
            storageLocations: [],
            albumPath: "2099/01/01/NonExistent"
        )

        let service = DeletionService()
        let result = await service.deleteImageFiles(
            images: [input],
            mountedVolumes: [("vol-1", root)],
            b2Credentials: nil,
            progress: progress
        )

        #expect(result.volumeFilesRemoved == 0)
        #expect(result.errors.isEmpty)

        // Existing files should be untouched
        let filePath = root.appendingPathComponent(TestFixtures.files[0].albumPath)
            .appendingPathComponent(TestFixtures.files[0].name)
        #expect(fm.fileExists(atPath: filePath.path))
    }

    @Test func deleteAllFixtureFilesFromVolume() async throws {
        let fm = FileManager.default
        let root = try TestFixtures.materializeVolume(label: "deletion-all")
        defer { try? fm.removeItem(at: root) }

        let service = DeletionService()

        // Delete each album separately (the service handles one album per call)
        var totalRemoved = 0
        for albumPath in TestFixtures.albumPaths {
            let albumFiles = TestFixtures.files.filter { $0.albumPath == albumPath }
            let progress = DeletionProgress()
            let inputs = albumFiles.map { spec in
                DeletionService.ImageDeletionInput(
                    sha256: spec.sha256,
                    filename: spec.name,
                    par2Filename: "",
                    b2FileId: nil,
                    storageLocations: [],
                    albumPath: spec.albumPath
                )
            }

            let result = await service.deleteImageFiles(
                images: inputs,
                mountedVolumes: [("vol-1", root)],
                b2Credentials: nil,
                progress: progress
            )

            #expect(result.errors.isEmpty)
            totalRemoved += result.volumeFilesRemoved
        }

        #expect(totalRemoved == TestFixtures.files.count)

        // Verify no fixture files remain
        for spec in TestFixtures.files {
            let path = root.appendingPathComponent(spec.albumPath).appendingPathComponent(spec.name)
            #expect(!fm.fileExists(atPath: path.path), "\(spec.name) should be deleted")
        }
    }

    @Test func deleteRemovesEmptyAncestorDirectories() async throws {
        let fm = FileManager.default
        let root = try TestFixtures.materializeVolume(label: "deletion-ancestors")
        defer { try? fm.removeItem(at: root) }

        // Delete only the Portraits album (2025/08/01/Portraits — sole album on that date)
        let portraits = TestFixtures.files(inAlbum: "Portraits")
        let progress = DeletionProgress()
        let inputs = portraits.map { spec in
            DeletionService.ImageDeletionInput(
                sha256: spec.sha256,
                filename: spec.name,
                par2Filename: "",
                b2FileId: nil,
                storageLocations: [],
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

        #expect(result.volumeFilesRemoved == portraits.count)

        // The entire 2025/08 tree should be gone (no other albums in month 08)
        let month08 = root.appendingPathComponent("2025/08")
        #expect(!fm.fileExists(atPath: month08.path), "Empty month directory should be removed")

        // But 2025/07 should still exist (Vacation and Nature albums are there)
        let month07 = root.appendingPathComponent("2025/07")
        #expect(fm.fileExists(atPath: month07.path), "Month with remaining albums should stay")

        // And 2025/ should still exist
        let year = root.appendingPathComponent("2025")
        #expect(fm.fileExists(atPath: year.path), "Year with remaining content should stay")
    }

    @Test func deleteAllFilesRemovesEntireTree() async throws {
        let fm = FileManager.default
        let root = try TestFixtures.materializeVolume(label: "deletion-tree")
        defer { try? fm.removeItem(at: root) }

        let service = DeletionService()

        // Delete each album separately
        for albumPath in TestFixtures.albumPaths {
            let albumFiles = TestFixtures.files.filter { $0.albumPath == albumPath }
            let progress = DeletionProgress()
            let inputs = albumFiles.map { spec in
                DeletionService.ImageDeletionInput(
                    sha256: spec.sha256,
                    filename: spec.name,
                    par2Filename: "",
                    b2FileId: nil,
                    storageLocations: [],
                    albumPath: spec.albumPath
                )
            }

            _ = await service.deleteImageFiles(
                images: inputs,
                mountedVolumes: [("vol-1", root)],
                b2Credentials: nil,
                progress: progress
            )
        }

        // All ancestor directories should be gone, only volume root remains
        let contents = try fm.contentsOfDirectory(atPath: root.path)
        #expect(contents.isEmpty, "Volume root should be empty after deleting all files, found: \(contents)")
    }

    @Test func deleteSingleImagePreservesOtherFiles() async throws {
        let fm = FileManager.default
        let root = try TestFixtures.materializeVolume(label: "deletion-single")
        defer { try? fm.removeItem(at: root) }

        // Delete only the first Vacation file, leaving the other two
        let target = TestFixtures.files[0] // sunset.heic in Vacation
        let others = TestFixtures.files(inAlbum: "Vacation").filter { $0.name != target.name }
        let progress = DeletionProgress()

        let input = DeletionService.ImageDeletionInput(
            sha256: target.sha256,
            filename: target.name,
            par2Filename: "",
            b2FileId: nil,
            storageLocations: [],
            albumPath: target.albumPath
        )

        let service = DeletionService()
        let result = await service.deleteImageFiles(
            images: [input],
            mountedVolumes: [("vol-1", root)],
            b2Credentials: nil,
            progress: progress,
            entireAlbum: false
        )

        #expect(result.volumeFilesRemoved == 1)
        #expect(result.errors.isEmpty)

        // Target file should be gone
        let deletedPath = root.appendingPathComponent(target.albumPath).appendingPathComponent(target.name)
        #expect(!fm.fileExists(atPath: deletedPath.path))

        // Other files in the same album should still exist
        for spec in others {
            let path = root.appendingPathComponent(spec.albumPath).appendingPathComponent(spec.name)
            #expect(fm.fileExists(atPath: path.path), "\(spec.name) should still exist")
        }
    }
}

// MARK: - Encryption Service Tests

@Suite
struct EncryptionServiceTests {
    private static let testPassphrase = "lumivault-test-passphrase"
    private static let testSalt = Data(repeating: 0x42, count: 32)
    private static let altPassphrase = "different-passphrase"
    private static let altSalt = Data(repeating: 0xAB, count: 32)

    private func serviceWithKey() async -> EncryptionService {
        let service = EncryptionService()
        let (key, keyId) = service.deriveKey(passphrase: Self.testPassphrase, salt: Self.testSalt)
        await service.setKey(key, keyId: keyId)
        return service
    }

    @Test func deriveKeyDeterministic() {
        let service = EncryptionService()
        let (key1, keyId1) = service.deriveKey(passphrase: Self.testPassphrase, salt: Self.testSalt)
        let (key2, keyId2) = service.deriveKey(passphrase: Self.testPassphrase, salt: Self.testSalt)

        #expect(key1 == key2)
        #expect(keyId1 == keyId2)
    }

    @Test func deriveKeyDifferentPassphrases() {
        let service = EncryptionService()
        let (key1, keyId1) = service.deriveKey(passphrase: Self.testPassphrase, salt: Self.testSalt)
        let (key2, keyId2) = service.deriveKey(passphrase: Self.altPassphrase, salt: Self.testSalt)

        #expect(key1 != key2)
        #expect(keyId1 != keyId2)
    }

    @Test func deriveKeyDifferentSalts() {
        let service = EncryptionService()
        let (key1, keyId1) = service.deriveKey(passphrase: Self.testPassphrase, salt: Self.testSalt)
        let (key2, keyId2) = service.deriveKey(passphrase: Self.testPassphrase, salt: Self.altSalt)

        #expect(key1 != key2)
        #expect(keyId1 != keyId2)
    }

    @Test func deriveKeyIdFormat() {
        let service = EncryptionService()
        let (_, keyId) = service.deriveKey(passphrase: Self.testPassphrase, salt: Self.testSalt)

        #expect(keyId.count == 16)
        #expect(keyId.allSatisfy { $0.isHexDigit })
    }

    @Test func setKeyAndClearKey() async {
        let service = EncryptionService()
        let (key, keyId) = service.deriveKey(passphrase: Self.testPassphrase, salt: Self.testSalt)

        await service.setKey(key, keyId: keyId)
        #expect(await service.isKeyAvailable == true)
        #expect(await service.cachedKeyId == keyId)

        await service.clearKey()
        #expect(await service.isKeyAvailable == false)
        #expect(await service.cachedKeyId == nil)
    }

    @Test func encryptDecryptRoundTripData() async throws {
        let service = await serviceWithKey()
        let plaintext = Data("LumiVault encryption test payload".utf8)

        let (ciphertext, nonce) = try await service.encrypt(data: plaintext)
        #expect(ciphertext != plaintext)

        let decrypted = try await service.decrypt(ciphertext: ciphertext, nonce: Data(nonce))
        #expect(decrypted == plaintext)
    }

    @Test func encryptDecryptWithAssociatedData() async throws {
        let service = await serviceWithKey()
        let plaintext = Data("payload with AD".utf8)
        let ad = Data("associated-context".utf8)

        let (ciphertext, nonce) = try await service.encrypt(data: plaintext, associatedData: ad)
        let decrypted = try await service.decrypt(ciphertext: ciphertext, nonce: Data(nonce), associatedData: ad)
        #expect(decrypted == plaintext)
    }

    @Test func decryptWithWrongKeyFails() async throws {
        let service = await serviceWithKey()
        let plaintext = Data("secret data".utf8)

        let (ciphertext, nonce) = try await service.encrypt(data: plaintext)

        // Switch to a different key
        let (altKey, altKeyId) = service.deriveKey(passphrase: Self.altPassphrase, salt: Self.altSalt)
        await service.setKey(altKey, keyId: altKeyId)

        do {
            _ = try await service.decrypt(ciphertext: ciphertext, nonce: Data(nonce))
            Issue.record("Expected decryption to throw with wrong key")
        } catch {
            // Expected — CryptoKit throws on authentication failure
        }
    }

    @Test func decryptWithWrongAssociatedDataFails() async throws {
        let service = await serviceWithKey()
        let plaintext = Data("payload".utf8)
        let correctAD = Data("correct".utf8)
        let wrongAD = Data("wrong".utf8)

        let (ciphertext, nonce) = try await service.encrypt(data: plaintext, associatedData: correctAD)

        do {
            _ = try await service.decrypt(ciphertext: ciphertext, nonce: Data(nonce), associatedData: wrongAD)
            Issue.record("Expected decryption to throw with wrong associated data")
        } catch {
            // Expected — GCM authentication fails
        }
    }

    @Test func encryptProducesUniqueNonces() async throws {
        let service = await serviceWithKey()
        let plaintext = Data("same content".utf8)

        var nonces = Set<Data>()
        for _ in 0..<50 {
            let (_, nonce) = try await service.encrypt(data: plaintext)
            nonces.insert(Data(nonce))
        }
        #expect(nonces.count == 50)
    }

    @Test func encryptWithNoKeyThrows() async {
        let service = EncryptionService()
        do {
            _ = try await service.encrypt(data: Data("test".utf8))
            Issue.record("Expected EncryptionError.noKey")
        } catch {
            #expect(error is EncryptionService.EncryptionError)
        }
    }

    @Test func encryptFileDecryptFileRoundTrip() async throws {
        let service = await serviceWithKey()
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-enc-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let plaintext = Data("File-level encryption test content for LumiVault".utf8)
        let sha256 = SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined()

        let sourceURL = tmpDir.appendingPathComponent("source.bin")
        let encryptedURL = tmpDir.appendingPathComponent("encrypted.bin")
        let decryptedURL = tmpDir.appendingPathComponent("decrypted.bin")

        try plaintext.write(to: sourceURL)

        let (nonce, encryptedSize) = try await service.encryptFile(at: sourceURL, to: encryptedURL, sha256: sha256)
        #expect(encryptedSize > 0)
        #expect(fm.fileExists(atPath: encryptedURL.path))

        try await service.decryptFile(at: encryptedURL, to: decryptedURL, nonce: nonce, sha256: sha256)
        let recovered = try Data(contentsOf: decryptedURL)
        #expect(recovered == plaintext)
    }

    @Test func encryptFileWithKeyStaticRoundTrip() async throws {
        let service = EncryptionService()
        let (key, keyId) = service.deriveKey(passphrase: Self.testPassphrase, salt: Self.testSalt)
        await service.setKey(key, keyId: keyId)

        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-encstatic-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let plaintext = Data("Static encryption method test".utf8)
        let sha256 = SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined()

        let sourceURL = tmpDir.appendingPathComponent("source.bin")
        let encryptedURL = tmpDir.appendingPathComponent("encrypted.bin")
        let decryptedURL = tmpDir.appendingPathComponent("decrypted.bin")

        try plaintext.write(to: sourceURL)

        let (nonce, _) = try EncryptionService.encryptFileWithKey(at: sourceURL, to: encryptedURL, sha256: sha256, key: key)

        // Decrypt with the instance method (proves interoperability)
        try await service.decryptFile(at: encryptedURL, to: decryptedURL, nonce: nonce, sha256: sha256)
        let recovered = try Data(contentsOf: decryptedURL)
        #expect(recovered == plaintext)
    }

    @Test func decryptDataInMemory() async throws {
        let service = await serviceWithKey()
        let plaintext = Data("In-memory decryption test".utf8)
        let sha256 = SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined()

        let (ciphertext, nonce) = try await service.encrypt(data: plaintext, associatedData: Data(sha256.utf8))
        let recovered = try await service.decryptData(ciphertext, nonce: Data(nonce), sha256: sha256)
        #expect(recovered == plaintext)
    }

    @Test func verifyGCMIntegrityPassesForValidFile() async throws {
        let service = EncryptionService()
        let (key, _) = service.deriveKey(passphrase: Self.testPassphrase, salt: Self.testSalt)

        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-gcm-verify-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let plaintext = Data("GCM integrity check test".utf8)
        let sha256 = SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined()
        let sourceURL = tmpDir.appendingPathComponent("source.bin")
        let encryptedURL = tmpDir.appendingPathComponent("encrypted.bin")
        try plaintext.write(to: sourceURL)

        let (nonce, _) = try EncryptionService.encryptFileWithKey(
            at: sourceURL, to: encryptedURL, sha256: sha256, key: key
        )

        let passed = try EncryptionService.verifyGCMIntegrity(
            at: encryptedURL, nonce: nonce, sha256: sha256, key: key
        )
        #expect(passed == true)
    }

    @Test func verifyGCMIntegrityFailsForCorruptedFile() async throws {
        let service = EncryptionService()
        let (key, _) = service.deriveKey(passphrase: Self.testPassphrase, salt: Self.testSalt)

        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-gcm-corrupt-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let plaintext = Data("GCM corruption detection test".utf8)
        let sha256 = SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined()
        let sourceURL = tmpDir.appendingPathComponent("source.bin")
        let encryptedURL = tmpDir.appendingPathComponent("encrypted.bin")
        try plaintext.write(to: sourceURL)

        let (nonce, _) = try EncryptionService.encryptFileWithKey(
            at: sourceURL, to: encryptedURL, sha256: sha256, key: key
        )

        // Corrupt a byte in the ciphertext
        var corrupted = try Data(contentsOf: encryptedURL)
        corrupted[corrupted.count / 2] ^= 0xFF
        try corrupted.write(to: encryptedURL)

        let passed = try EncryptionService.verifyGCMIntegrity(
            at: encryptedURL, nonce: nonce, sha256: sha256, key: key
        )
        #expect(passed == false)
    }

    @Test func verifyGCMIntegrityFailsForWrongKey() async throws {
        let service = EncryptionService()
        let (key, _) = service.deriveKey(passphrase: Self.testPassphrase, salt: Self.testSalt)
        let (wrongKey, _) = service.deriveKey(passphrase: Self.altPassphrase, salt: Self.testSalt)

        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-gcm-wrongkey-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let plaintext = Data("GCM wrong key test".utf8)
        let sha256 = SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined()
        let sourceURL = tmpDir.appendingPathComponent("source.bin")
        let encryptedURL = tmpDir.appendingPathComponent("encrypted.bin")
        try plaintext.write(to: sourceURL)

        let (nonce, _) = try EncryptionService.encryptFileWithKey(
            at: sourceURL, to: encryptedURL, sha256: sha256, key: key
        )

        let passed = try EncryptionService.verifyGCMIntegrity(
            at: encryptedURL, nonce: nonce, sha256: sha256, key: wrongKey
        )
        #expect(passed == false)
    }
}

// MARK: - B2 Service Helper Tests

@Suite
struct B2ServiceHelperTests {
    @Test func sha1HashKnownValue() {
        let hash = B2Service.sha1Hash(of: Data("hello".utf8))
        #expect(hash == "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
    }

    @Test func sha1HashEmptyData() {
        let hash = B2Service.sha1Hash(of: Data())
        #expect(hash == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    @Test func sha1HashFixtureContent() {
        let content = Data("LumiVault B2 test fixture".utf8)
        let hash = B2Service.sha1Hash(of: content)
        #expect(hash.count == 40)
        #expect(hash.allSatisfy { $0.isHexDigit })
    }

    @Test func checkResponseSuccess200() throws {
        let url = URL(string: "https://api.example.com")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        try B2Service.checkResponse(response, data: nil)
    }

    @Test func checkResponseSuccess299() throws {
        let url = URL(string: "https://api.example.com")!
        let response = HTTPURLResponse(url: url, statusCode: 299, httpVersion: nil, headerFields: nil)!
        try B2Service.checkResponse(response, data: nil)
    }

    @Test func checkResponseError401() {
        let url = URL(string: "https://api.example.com")!
        let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
        let body = try? JSONSerialization.data(withJSONObject: ["message": "Unauthorized"])

        do {
            try B2Service.checkResponse(response, data: body)
            Issue.record("Expected B2Error.httpError")
        } catch let error as B2Service.B2Error {
            if case .httpError(let code, let message) = error {
                #expect(code == 401)
                #expect(message == "Unauthorized")
            } else {
                Issue.record("Expected httpError, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func checkResponseError500NoBody() {
        let url = URL(string: "https://api.example.com")!
        let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!

        do {
            try B2Service.checkResponse(response, data: nil)
            Issue.record("Expected B2Error.httpError")
        } catch let error as B2Service.B2Error {
            if case .httpError(let code, let message) = error {
                #expect(code == 500)
                #expect(message == nil)
            } else {
                Issue.record("Expected httpError, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

// MARK: - Import Progress Tests

@Suite @MainActor
struct PhotosImportProgressTests {
    @Test func fractionZeroWhenEmpty() {
        let progress = PhotosImportProgress()
        progress.totalFiles = 0
        #expect(progress.fraction == 0)
    }

    @Test func fractionDuringImportPhase() {
        let progress = PhotosImportProgress()
        progress.totalFiles = 20
        progress.phase = .importing
        progress.currentFile = 10

        // Import phase: (10/20) * 0.1 = 0.05
        #expect(abs(progress.fraction - 0.05) < 0.001)
    }

    @Test func fractionMidPipeline() {
        let progress = PhotosImportProgress()
        progress.totalFiles = 20
        progress.phase = .hashing
        progress.filesCataloged = 10

        // Post-import phases: 0.1 + (10/20) * 0.9 = 0.55
        #expect(abs(progress.fraction - 0.55) < 0.001)
    }

    @Test func fractionOneWhenComplete() {
        let progress = PhotosImportProgress()
        progress.totalFiles = 5
        progress.phase = .complete

        #expect(progress.fraction == 1.0)
    }

    @Test func fractionWithGlobalProgress() {
        let progress = PhotosImportProgress()
        progress.globalTotalFiles = 100
        progress.completedAlbumFiles = 50
        progress.totalFiles = 20
        progress.phase = .hashing
        progress.filesCataloged = 10

        // Album fraction: 0.1 + (10/20) * 0.9 = 0.55
        // Global: 50/100 + 0.55 * (20/100) = 0.5 + 0.11 = 0.61
        #expect(abs(progress.fraction - 0.61) < 0.001)
    }

    @Test func fractionUsesCompletedAlbumsWhenCurrentEmpty() {
        let progress = PhotosImportProgress()
        progress.globalTotalFiles = 100
        progress.completedAlbumFiles = 30
        progress.totalFiles = 0

        // No files in current album yet — show completed albums progress
        #expect(abs(progress.fraction - 0.3) < 0.001)
    }
}

// MARK: - Catalog Backup Service Tests

@Suite @MainActor
struct CatalogBackupServiceTests {
    @Test func backupToVolumeWritesCatalogJSON() async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-backup-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let catalog = TestFixtures.catalog()
        let service = CatalogBackupService()
        let volume = VolumeSnapshot(volumeID: "vol-test", label: "TestVol", mountURL: tmpDir)

        let errors = await service.backupToVolumes(catalog: catalog, volumes: [volume])
        #expect(errors.isEmpty)

        let catalogURL = tmpDir.appendingPathComponent("catalog.json")
        #expect(fm.fileExists(atPath: catalogURL.path))

        // Decode and verify
        let data = try Data(contentsOf: catalogURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(Catalog.self, from: data)
        #expect(restored.version == catalog.version)

        // Count total images
        let originalCount = catalog.years.values.flatMap { $0.months.values }.flatMap { $0.days.values }.flatMap { $0.albums.values }.flatMap { $0.images }.count
        let restoredCount = restored.years.values.flatMap { $0.months.values }.flatMap { $0.days.values }.flatMap { $0.albums.values }.flatMap { $0.images }.count
        #expect(restoredCount == originalCount)
    }

    @Test func backupToVolumeReportsErrorForBadPath() async {
        let service = CatalogBackupService()
        let catalog = TestFixtures.catalog()
        let badURL = URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)")
        let volume = VolumeSnapshot(volumeID: "vol-bad", label: "BadVol", mountURL: badURL)

        let errors = await service.backupToVolumes(catalog: catalog, volumes: [volume])
        #expect(!errors.isEmpty)
    }

    @Test func restoreFromFileRoundTrip() async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-restore-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let catalog = TestFixtures.catalog()

        // Write catalog to file
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(catalog)
        let fileURL = tmpDir.appendingPathComponent("catalog.json")
        try data.write(to: fileURL)

        let service = CatalogBackupService()
        let restored = try await service.restoreFromFile(url: fileURL)

        #expect(restored.version == catalog.version)
        let originalHashes = Set(catalog.years.values.flatMap { $0.months.values }.flatMap { $0.days.values }.flatMap { $0.albums.values }.flatMap { $0.images }.map(\.sha256))
        let restoredHashes = Set(restored.years.values.flatMap { $0.months.values }.flatMap { $0.days.values }.flatMap { $0.albums.values }.flatMap { $0.images }.map(\.sha256))
        #expect(originalHashes == restoredHashes)
    }

    @Test func restoreFromVolumeThrowsWhenMissing() async {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-norestore-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let service = CatalogBackupService()
        do {
            _ = try await service.restoreFromVolume(volumeURL: tmpDir)
            Issue.record("Expected RestoreError.catalogNotFound")
        } catch {
            #expect(error is CatalogBackupService.RestoreError)
        }
    }
}

// MARK: - Image Conversion Tests

@Suite @MainActor
struct ImageConversionTests {
    @Test func convertToJPEGChangesExtension() async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-conv-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let sourceURL = tmpDir.appendingPathComponent("photo.heic")
        try TestFixtures.createTinyJPEG(at: sourceURL, width: 100, height: 100)

        let staging = tmpDir.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let asset = ImportedAsset(fileURL: sourceURL, originalFilename: "photo.heic", creationDate: nil)
        let result = ImageConversionService.convertImage(asset: asset, format: ImageFormat.jpeg, quality: 0.85, maxDimension: MaxDimension.original, staging: staging)

        #expect(result.fileURL.pathExtension == "jpg")
    }

    @Test func convertToJPEGProducesValidImage() async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-conv-valid-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let sourceURL = tmpDir.appendingPathComponent("photo.png")
        try TestFixtures.createTinyJPEG(at: sourceURL, width: 200, height: 150)

        let staging = tmpDir.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let asset = ImportedAsset(fileURL: sourceURL, originalFilename: "photo.png", creationDate: nil)
        let result = ImageConversionService.convertImage(asset: asset, format: ImageFormat.jpeg, quality: 0.85, maxDimension: MaxDimension.original, staging: staging)

        let image = NSImage(contentsOf: result.fileURL)
        #expect(image != nil)
        #expect(image!.representations.first!.pixelsWide > 0)
        #expect(image!.representations.first!.pixelsHigh > 0)
    }

    @Test func convertWithMaxDimensionScalesDown() async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-conv-scale-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let sourceURL = tmpDir.appendingPathComponent("large.png")
        try TestFixtures.createTinyJPEG(at: sourceURL, width: 200, height: 100)

        let staging = tmpDir.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let asset = ImportedAsset(fileURL: sourceURL, originalFilename: "large.png", creationDate: nil)
        let result = ImageConversionService.convertImage(asset: asset, format: ImageFormat.jpeg, quality: 0.85, maxDimension: MaxDimension.capped(50), staging: staging)

        let image = NSImage(contentsOf: result.fileURL)
        #expect(image != nil)
        let rep = image!.representations.first!
        // Longest edge (200) scaled to 50 → scale = 0.25 → 50x25
        #expect(rep.pixelsWide <= 50)
        #expect(rep.pixelsHigh <= 25)
    }

    @Test func convertOriginalFormatReturnsUnchanged() async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-conv-noop-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let sourceURL = tmpDir.appendingPathComponent("photo.heic")
        try TestFixtures.createTinyJPEG(at: sourceURL, width: 50, height: 50)

        let staging = tmpDir.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let asset = ImportedAsset(fileURL: sourceURL, originalFilename: "photo.heic", creationDate: nil)
        let result = ImageConversionService.convertImage(asset: asset, format: ImageFormat.original, quality: 0.85, maxDimension: MaxDimension.original, staging: staging)

        // No conversion needed — same URL returned
        #expect(result.fileURL == sourceURL)
    }

    @Test func convertPreservesWhenBelowMax() async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-conv-small-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let sourceURL = tmpDir.appendingPathComponent("small.png")
        try TestFixtures.createTinyJPEG(at: sourceURL, width: 50, height: 50)

        let staging = tmpDir.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let asset = ImportedAsset(fileURL: sourceURL, originalFilename: "small.png", creationDate: nil)
        let result = ImageConversionService.convertImage(asset: asset, format: ImageFormat.jpeg, quality: 0.85, maxDimension: MaxDimension.capped(200), staging: staging)

        let image = NSImage(contentsOf: result.fileURL)
        #expect(image != nil)
        let rep = image!.representations.first!
        // 50x50 is below 200 cap — should remain 50x50
        #expect(rep.pixelsWide == 50)
        #expect(rep.pixelsHigh == 50)
    }
}

// MARK: - Perceptual Hash Compute Tests

@Suite
struct PerceptualHashComputeTests {
    @Test func computeReturnsEightBytes() throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-phash-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let url = tmpDir.appendingPathComponent("test.jpg")
        try TestFixtures.createTinyJPEG(at: url, width: 32, height: 32)

        let hash = try PerceptualHash.compute(for: url)
        #expect(hash.count == 8)
    }

    @Test func computeIsDeterministic() throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-phash-det-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let url = tmpDir.appendingPathComponent("test.jpg")
        try TestFixtures.createTinyJPEG(at: url, width: 32, height: 32)

        let hash1 = try PerceptualHash.compute(for: url)
        let hash2 = try PerceptualHash.compute(for: url)
        #expect(hash1 == hash2)
    }

    @Test func computeThrowsForNonImageFile() {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-phash-bad-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let url = tmpDir.appendingPathComponent("notanimage.bin")
        try? Data("this is not an image".utf8).write(to: url)

        do {
            _ = try PerceptualHash.compute(for: url)
            Issue.record("Expected PerceptualHashError.unreadable")
        } catch {
            // Expected — CIImage cannot read non-image data
        }
    }
}

// MARK: - Encrypt → PAR2 → Decrypt Integration Tests

@Suite
struct EncryptPAR2IntegrationTests {
    private static let testPassphrase = "integration-test-key"
    private static let testSalt = Data(repeating: 0x77, count: 32)

    @Test func encryptPAR2RepairDecryptRoundTrip() async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-enc-par2-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // Step 1: Write original file
        let plaintext = Data((0..<2048).map { UInt8(($0 * 37 + 13) % 256) })
        let originalURL = tmpDir.appendingPathComponent("original.bin")
        try plaintext.write(to: originalURL)

        let hasher = HasherService()
        let (sha256, _) = try await hasher.sha256AndSize(of: originalURL)

        // Step 2: Encrypt
        let encryptionService = EncryptionService()
        let (key, keyId) = encryptionService.deriveKey(passphrase: Self.testPassphrase, salt: Self.testSalt)
        await encryptionService.setKey(key, keyId: keyId)

        let encryptedURL = tmpDir.appendingPathComponent("encrypted.bin")
        let (nonce, _) = try await encryptionService.encryptFile(at: originalURL, to: encryptedURL, sha256: sha256)

        // Step 3: Generate PAR2 on the encrypted file
        let redundancy = RedundancyService()
        let par2URL = try redundancy.generatePAR2(for: encryptedURL, outputDirectory: tmpDir)

        // Step 4: Corrupt the encrypted file (flip bytes in the middle)
        var encryptedData = try Data(contentsOf: encryptedURL)
        let corruptStart = encryptedData.count / 3
        for i in corruptStart..<min(corruptStart + 50, encryptedData.count - 16) {
            encryptedData[i] ^= 0xFF
        }
        try encryptedData.write(to: encryptedURL)

        // Step 5: Verify the file was actually changed by checking decryption fails
        do {
            let tmpDec = tmpDir.appendingPathComponent("should-fail.bin")
            try await encryptionService.decryptFile(at: encryptedURL, to: tmpDec, nonce: nonce, sha256: sha256)
            Issue.record("Decryption should fail on corrupted ciphertext")
        } catch {
            // Expected — corrupted ciphertext fails GCM authentication
        }

        // Step 6: Repair using PAR2
        let repairedData = try redundancy.repair(par2URL: par2URL, corruptedFileURL: encryptedURL)
        #expect(repairedData != nil, "PAR2 should repair the encrypted file")
        guard let repairedData else { return }

        // Write repaired data back
        try repairedData.write(to: encryptedURL)

        // Step 7: Decrypt the repaired file
        let decryptedURL = tmpDir.appendingPathComponent("decrypted.bin")
        try await encryptionService.decryptFile(at: encryptedURL, to: decryptedURL, nonce: nonce, sha256: sha256)

        // Step 8: Verify decrypted content matches original
        let recovered = try Data(contentsOf: decryptedURL)
        #expect(recovered == plaintext, "Decrypted content should match original after PAR2 repair")
    }

    @Test func encryptedFilePassesPAR2VerificationWhenUncorrupted() async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-enc-par2-ok-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let plaintext = Data((0..<1024).map { UInt8(($0 * 53 + 7) % 256) })
        let originalURL = tmpDir.appendingPathComponent("original.bin")
        try plaintext.write(to: originalURL)

        let hasher = HasherService()
        let (sha256, _) = try await hasher.sha256AndSize(of: originalURL)

        let encryptionService = EncryptionService()
        let (key, keyId) = encryptionService.deriveKey(passphrase: Self.testPassphrase, salt: Self.testSalt)
        await encryptionService.setKey(key, keyId: keyId)

        let encryptedURL = tmpDir.appendingPathComponent("encrypted.bin")
        _ = try await encryptionService.encryptFile(at: originalURL, to: encryptedURL, sha256: sha256)

        let redundancy = RedundancyService()
        let par2URL = try redundancy.generatePAR2(for: encryptedURL, outputDirectory: tmpDir)

        let verified = try redundancy.verify(par2URL: par2URL, originalFileURL: encryptedURL)
        #expect(verified, "Uncorrupted encrypted file should pass PAR2 verification")
    }
}

// MARK: - Catalog Backup Service Additional Tests

@Suite @MainActor
struct CatalogBackupRestoreTests {
    @Test func restoreFromVolumeHappyPath() async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-vol-restore-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // Write catalog.json to simulate a volume with backup
        let catalog = TestFixtures.catalog()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(catalog)
        try data.write(to: tmpDir.appendingPathComponent("catalog.json"))

        let service = CatalogBackupService()
        let restored = try await service.restoreFromVolume(volumeURL: tmpDir)

        #expect(restored.version == catalog.version)

        // Verify all fixture hashes present
        let restoredHashes = Set(
            restored.years.values
                .flatMap { $0.months.values }
                .flatMap { $0.days.values }
                .flatMap { $0.albums.values }
                .flatMap { $0.images }
                .map(\.sha256)
        )
        for spec in TestFixtures.files {
            #expect(restoredHashes.contains(spec.sha256), "\(spec.name) hash missing after restore")
        }
    }
}

// MARK: - Encryption Service Edge Case Tests

@Suite
struct EncryptionEdgeCaseTests {
    private static let testPassphrase = "edge-case-passphrase"
    private static let testSalt = Data(repeating: 0x33, count: 32)

    private func serviceWithKey() async -> EncryptionService {
        let service = EncryptionService()
        let (key, keyId) = service.deriveKey(passphrase: Self.testPassphrase, salt: Self.testSalt)
        await service.setKey(key, keyId: keyId)
        return service
    }

    @Test func encryptDecryptEmptyData() async throws {
        let service = await serviceWithKey()
        let empty = Data()

        let (ciphertext, nonce) = try await service.encrypt(data: empty)
        // GCM tag is 16 bytes, so ciphertext of empty plaintext = 16 bytes
        #expect(ciphertext.count == 16)

        let decrypted = try await service.decrypt(ciphertext: ciphertext, nonce: Data(nonce))
        #expect(decrypted == empty)
        #expect(decrypted.isEmpty)
    }

    @Test func encryptedSizeEqualsPlaintextPlusTag() async throws {
        let service = await serviceWithKey()

        for size in [1, 100, 1000, 10000] {
            let plaintext = Data(repeating: 0xAB, count: size)
            let (ciphertext, _) = try await service.encrypt(data: plaintext)
            // AES-GCM: ciphertext = plaintext + 16-byte tag
            #expect(ciphertext.count == size + 16, "Size \(size): expected \(size + 16), got \(ciphertext.count)")
        }
    }

    @Test func encryptDecryptLargeData() async throws {
        let service = await serviceWithKey()
        // 1 MB of data
        let large = Data((0..<1_048_576).map { UInt8($0 % 256) })

        let (ciphertext, nonce) = try await service.encrypt(data: large)
        let decrypted = try await service.decrypt(ciphertext: ciphertext, nonce: Data(nonce))
        #expect(decrypted == large)
    }

    @Test func encryptFileProducesCorrectSize() async throws {
        let service = await serviceWithKey()
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-enc-size-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let plaintext = Data(repeating: 0x42, count: 4096)
        let sha256 = CryptoKit.SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined()

        let sourceURL = tmpDir.appendingPathComponent("source.bin")
        let encryptedURL = tmpDir.appendingPathComponent("encrypted.bin")
        try plaintext.write(to: sourceURL)

        let (_, encryptedSize) = try await service.encryptFile(at: sourceURL, to: encryptedURL, sha256: sha256)
        // File-level encryption: ciphertext + 16-byte GCM tag
        #expect(encryptedSize == Int64(4096 + 16))
    }
}

// MARK: - Import Settings Tests

@Suite
@MainActor
struct ImportSettingsTests {
    @Test func nearDuplicateThresholdDefaultMatchesConstant() {
        let settings = ImportSettings(albumName: "x", year: "2025", month: "01", day: "01")
        #expect(settings.nearDuplicateThreshold == Constants.Dedup.nearDuplicateThreshold)
    }
}

// MARK: - Photos Library Monitor Diff Tests

@Suite
@MainActor
struct PhotosLibraryMonitorDiffTests {
    private func makeImage(sha: String, phId: String?) -> ImageRecord {
        ImageRecord(
            sha256: sha,
            filename: "\(sha).jpg",
            sizeBytes: 1,
            phAssetLocalIdentifier: phId
        )
    }

    @Test func diffDetectsAdditionsAndRemovals() {
        let kept = makeImage(sha: "k", phId: "id-keep")
        let removed = makeImage(sha: "r", phId: "id-gone")
        let photoIds: Set<String> = ["id-keep", "id-new1", "id-new2"]

        let parts = PhotosLibraryMonitor.computeDeltaParts(
            photoIds: photoIds,
            catalogImages: [kept, removed]
        )

        #expect(parts.addedIds == ["id-new1", "id-new2"])
        #expect(parts.removed.map(\.sha256) == ["r"])
        #expect(parts.untrackable.isEmpty)
    }

    @Test func diffExcludesNilIdImagesFromRemoval() {
        let legacy = makeImage(sha: "legacy", phId: nil)
        let tracked = makeImage(sha: "tracked", phId: "id-1")

        let parts = PhotosLibraryMonitor.computeDeltaParts(
            photoIds: ["id-1"],
            catalogImages: [legacy, tracked]
        )

        #expect(parts.addedIds.isEmpty)
        #expect(parts.removed.isEmpty)
        #expect(parts.untrackable.map(\.sha256) == ["legacy"])
    }

    @Test func diffWithEmptyPhotoLibraryRemovesAllTracked() {
        let a = makeImage(sha: "a", phId: "id-a")
        let b = makeImage(sha: "b", phId: "id-b")
        let legacy = makeImage(sha: "legacy", phId: nil)

        let parts = PhotosLibraryMonitor.computeDeltaParts(
            photoIds: [],
            catalogImages: [a, b, legacy]
        )

        #expect(parts.addedIds.isEmpty)
        #expect(Set(parts.removed.map(\.sha256)) == ["a", "b"])
        #expect(parts.untrackable.map(\.sha256) == ["legacy"])
    }

    @Test func diffNoChanges() {
        let a = makeImage(sha: "a", phId: "id-a")
        let parts = PhotosLibraryMonitor.computeDeltaParts(
            photoIds: ["id-a"],
            catalogImages: [a]
        )
        #expect(parts.addedIds.isEmpty)
        #expect(parts.removed.isEmpty)
        #expect(parts.untrackable.isEmpty)
    }
}

// MARK: - SwiftData Schema Migration Smoke Test

@Suite
@MainActor
struct PhotosSyncSchemaTests {
    @Test func newNullableFieldsDefaultToNil() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ImageRecord.self, AlbumRecord.self, VolumeRecord.self,
            configurations: config
        )
        let context = container.mainContext

        let album = AlbumRecord(name: "Test", year: "2025", month: "07", day: "15")
        context.insert(album)

        let image = ImageRecord(sha256: "deadbeef", filename: "x.jpg", sizeBytes: 1)
        image.album = album
        context.insert(image)
        try context.save()

        #expect(album.photosAlbumLocalIdentifier == nil)
        #expect(image.phAssetLocalIdentifier == nil)
    }

    @Test func explicitIdentifiersPersist() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ImageRecord.self, AlbumRecord.self, VolumeRecord.self,
            configurations: config
        )
        let context = container.mainContext

        let album = AlbumRecord(
            name: "Test",
            year: "2025",
            month: "07",
            day: "15",
            photosAlbumLocalIdentifier: "PH-album-1"
        )
        context.insert(album)
        let image = ImageRecord(
            sha256: "deadbeef",
            filename: "x.jpg",
            sizeBytes: 1,
            phAssetLocalIdentifier: "PH-asset-1"
        )
        image.album = album
        context.insert(image)
        try context.save()

        #expect(album.photosAlbumLocalIdentifier == "PH-album-1")
        #expect(image.phAssetLocalIdentifier == "PH-asset-1")
    }
}
