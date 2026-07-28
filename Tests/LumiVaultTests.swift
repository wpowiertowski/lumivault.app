import Testing
import Foundation
import SwiftData
import CryptoKit
import AppKit
import ImageIO
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

    @Test func staleVolFilesIdentifiesOrphansOnly() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumivault-stale-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // Seed the directory with: index, one current vol, two orphan vols from earlier
        // generations, plus an unrelated file that must not be touched.
        let placeholders = [
            "catalog.json.par2",
            "catalog.json.vol0+1.par2",   // orphan
            "catalog.json.vol0+5.par2",   // orphan
            "catalog.json.vol0+16.par2",  // current
            "catalog.json",               // unrelated
            "other.par2",                 // unrelated
        ]
        for name in placeholders {
            try Data().write(to: dir.appendingPathComponent(name))
        }

        let stale = RedundancyService.staleVolFiles(
            forIndex: "catalog.json.par2",
            keep: ["catalog.json.par2", "catalog.json.vol0+16.par2"],
            in: dir
        )

        let staleNames = Set(stale.map { $0.lastPathComponent })
        #expect(staleNames == ["catalog.json.vol0+1.par2", "catalog.json.vol0+5.par2"])
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

    @Test func par2LogicalNameOverridesCompanionNaming() async throws {
        // When two distinct assets share an originalFilename, the import stage
        // stores the second under a disambiguated name and passes it as
        // `logicalName` so PAR2 companions match the *stored* name (not the
        // staging file's name) while the recovery data still covers the bytes.
        let service = RedundancyService()
        let spec = TestFixtures.files[4] // city.heic, 3072 bytes
        let root = try TestFixtures.materializeVolume(label: "par2-logical")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponent(spec.albumPath)
        let fileURL = dir.appendingPathComponent(spec.name)
        let logical = "city~deadbeef.heic"

        let par2URL = try service.generatePAR2(for: fileURL, outputDirectory: dir, logicalName: logical)

        // Index + companions are named after the logical name, not the file.
        #expect(par2URL.lastPathComponent == "\(logical).par2")
        let companions = RedundancyService.companionFiles(forIndex: par2URL.lastPathComponent, in: dir)
        #expect(companions.allSatisfy { $0.lastPathComponent.hasPrefix(logical) })
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(spec.name).par2").path))

        // Recovery data still covers the original bytes, so verify passes.
        let isValid = try service.verify(par2URL: par2URL, originalFileURL: fileURL)
        #expect(isValid)
    }

}

// MARK: - Filename Disambiguation Tests

@Suite @MainActor
struct FilenameDisambiguationTests {
    @Test func distinctShasYieldDistinctNamesForSameBase() {
        let a = PipelinedImportCoordinator.disambiguatedFilename("IMG_1613.heic", sha256: "aaaaaaaa1111")
        let b = PipelinedImportCoordinator.disambiguatedFilename("IMG_1613.heic", sha256: "bbbbbbbb2222")
        #expect(a != b)
        #expect(a == "IMG_1613~aaaaaaaa.heic")
        #expect(b == "IMG_1613~bbbbbbbb.heic")
    }

    @Test func handlesNoExtension() {
        let name = PipelinedImportCoordinator.disambiguatedFilename("IMG_1613", sha256: "0123456789ab")
        #expect(name == "IMG_1613~01234567")
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

    /// Hashes read back from SwiftData are often slices whose backing buffer is not
    /// 8-byte aligned. An aligned `load(as: UInt64.self)` traps on those; this exercises
    /// the unaligned path on both operands to guard against that regression.
    @Test func hammingDistanceMisalignedBackingBuffer() {
        // dropFirst() yields a Data slice starting at offset 1 — guaranteed misaligned
        // for UInt64 relative to the (aligned) base allocation.
        let payload: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]
        let misalignedA = Data([0x00] + payload).dropFirst()
        let misalignedB = Data([0x00] + payload).dropFirst()
        #expect(misalignedA.count == 8)
        // Must not trap, and must equal the aligned result for the same bytes.
        #expect(PerceptualHash.hammingDistance(Data(misalignedA), Data(misalignedB)) == 0)
        #expect(PerceptualHash.hammingDistance(misalignedA, misalignedB) == 0)

        let complement = Data(payload.map { ~$0 })
        #expect(PerceptualHash.hammingDistance(misalignedA, complement) == 64)
    }
}

// MARK: - EXIF Formatting Tests

@Suite @MainActor
struct EXIFDataFormattingTests {
    @Test func exposureStringFormatsSubSecond() {
        var exif = EXIFData()
        exif.exposureTime = 1.0 / 250.0
        #expect(exif.exposureString == "1/250s")
    }

    @Test func exposureStringFormatsLongExposure() {
        var exif = EXIFData()
        exif.exposureTime = 2.0
        #expect(exif.exposureString == "2.0s")
    }

    @Test func exposureStringNilWhenAbsent() {
        let exif = EXIFData()
        #expect(exif.exposureString == nil)
    }

    /// A corrupt/zero ExposureTime tag previously evaluated Int(round(1.0/0)) = Int(.infinity),
    /// which traps. It must now be treated as absent rather than crash the inspector.
    @Test func exposureStringZeroDoesNotTrap() {
        var exif = EXIFData()
        exif.exposureTime = 0
        #expect(exif.exposureString == nil)
    }
}

// MARK: - Near-Duplicate Clustering Tests

@Suite @MainActor
struct NearDuplicateClusteringTests {
    private func item(_ sha: String, _ bytes: [UInt8]) -> NearDuplicateClustering.Item {
        var padded = bytes
        padded.append(contentsOf: Array(repeating: 0, count: max(0, 8 - bytes.count)))
        return NearDuplicateClustering.Item(
            sha256: sha, filename: "\(sha).jpg", sizeBytes: 1, albumName: "A",
            hash: Data(padded.prefix(8))
        )
    }

    /// A≈B (dist 6) and B≈C (dist 6) but A≉C (dist 12). With an anchor-only comparison
    /// C would be dropped from A's group; transitive growth must include all three.
    @Test func clustersTransitiveChain() {
        let a = item("a", [0x00])               // 0 bits
        let b = item("b", [0x3F])               // 6 bits  -> dist(a,b)=6
        let c = item("c", [0x3F, 0x3F])         // 12 bits -> dist(a,c)=12, dist(b,c)=6
        let groups = NearDuplicateClustering.groups(from: [a, b, c], threshold: 10)
        #expect(groups.count == 1)
        let shas = Set(groups.first?.members.map(\.sha256) ?? [])
        #expect(shas == ["a", "b", "c"])
    }

    @Test func separateClustersStaySeparate() {
        let a = item("a", [0x00])
        let b = item("b", [0x01])               // dist(a,b)=1
        let x = item("x", [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let y = item("y", [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE]) // dist(x,y)=1
        let groups = NearDuplicateClustering.groups(from: [a, b, x, y], threshold: 10)
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.members.count == 2 })
    }

    @Test func noNearDuplicatesYieldsNoGroups() {
        let a = item("a", [0x00])
        let b = item("b", [0xFF, 0xFF, 0xFF])   // dist(a,b)=24, above threshold
        let groups = NearDuplicateClustering.groups(from: [a, b], threshold: 10)
        #expect(groups.isEmpty)
    }

    @Test func singletonNeverGroupsWithItself() {
        let groups = NearDuplicateClustering.groups(from: [item("a", [0x00])], threshold: 10)
        #expect(groups.isEmpty)
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
            image.albums = [album]
            context.insert(image)
        }

        try context.save()

        #expect(album.images.count == specs.count) // 3 Vacation images
        #expect(album.images.allSatisfy { $0.albums.contains { a in a.name == "Vacation" } })
    }

    /// Pins every default on the persisted record in one place. These are the values
    /// an existing store's rows take on after a schema addition, so a changed default
    /// silently rewrites the meaning of already-archived records.
    @Test func imageRecordDefaults() throws {
        let spec = TestFixtures.files[0]
        let image = ImageRecord(sha256: spec.sha256, filename: spec.name, sizeBytes: Int64(spec.size))

        #expect(image.thumbnailState == .pending)
        #expect(image.perceptualHash == nil)
        #expect(image.b2FileId == nil)
        #expect(image.lastVerifiedAt == nil)
        #expect(image.storageLocations.isEmpty)
        #expect(image.par2Filename == "")

        // Media fields added after the first release: a record that predates them
        // must read back as a plain image with no dimensions.
        #expect(image.mediaType == .image)
        #expect(image.durationSeconds == nil)
        #expect(image.pixelWidth == nil)
        #expect(image.pixelHeight == nil)
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

    @Test func removeImagePrunesEmptyAlbumAndContainers() async {
        let service = CatalogService()
        let spec = TestFixtures.files[0]
        let image = CatalogImage(filename: spec.name, sha256: spec.sha256, sizeBytes: Int64(spec.size), par2Filename: spec.par2Name)
        await service.addImage(image, toAlbum: "Solo", year: "2024", month: "12", day: "25")

        // Removing the only image must not leave a ghost empty album behind, and the
        // now-empty day/month/year containers should be pruned too (matching removeAlbum).
        await service.removeImage(sha256: spec.sha256, fromAlbum: "Solo", year: "2024", month: "12", day: "25")

        let catalog = await service.currentCatalog()
        #expect(catalog.years["2024"] == nil)
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

    /// 299 rather than 200: the upper edge of the accepted range is the value a
    /// mistaken `..<` / `...` boundary would get wrong.
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

    @Test func backupToVolumeEvictsOrphanVolFiles() async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-evict-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // Seed two orphan vol files with large counts that can't match the recovery-block
        // count of the small TestFixtures catalog (which has only 1 block).
        let orphan1 = tmpDir.appendingPathComponent("catalog.json.vol0+88.par2")
        let orphan2 = tmpDir.appendingPathComponent("catalog.json.vol0+99.par2")
        try Data([0xDE, 0xAD]).write(to: orphan1)
        try Data([0xBE, 0xEF]).write(to: orphan2)

        let catalog = TestFixtures.catalog()
        let service = CatalogBackupService()
        let volume = VolumeSnapshot(volumeID: "vol-evict", label: "EvictVol", mountURL: tmpDir)

        let errors = await service.backupToVolumes(catalog: catalog, volumes: [volume])
        #expect(errors.isEmpty)

        #expect(!fm.fileExists(atPath: orphan1.path))
        #expect(!fm.fileExists(atPath: orphan2.path))

        // Exactly one current vol file should remain alongside the index.
        let companions = RedundancyService.companionFiles(forIndex: "catalog.json.par2", in: tmpDir)
        let volFiles = companions.filter { $0.lastPathComponent.contains(".vol") }
        #expect(volFiles.count == 1)
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

    @Test func convertKeepsSameNamedDuplicatesDistinct() async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-conv-dup-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // Two distinct images that share an original filename — like a Photos
        // asset duplicated with a different crop. The export step uniquifies
        // only the on-disk temp name, not `originalFilename`.
        let firstURL = tmpDir.appendingPathComponent("IMG_0001.png")
        let secondURL = tmpDir.appendingPathComponent("IMG_0001_1.png")
        try TestFixtures.createTinyJPEG(at: firstURL, width: 100, height: 100)
        try TestFixtures.createTinyJPEG(at: secondURL, width: 60, height: 60)

        let staging = tmpDir.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let first = ImageConversionService.convertImage(
            asset: ImportedAsset(fileURL: firstURL, originalFilename: "IMG_0001.png", creationDate: nil),
            format: ImageFormat.jpeg, quality: 0.85, maxDimension: MaxDimension.original, staging: staging
        )
        let second = ImageConversionService.convertImage(
            asset: ImportedAsset(fileURL: secondURL, originalFilename: "IMG_0001.png", creationDate: nil),
            format: ImageFormat.jpeg, quality: 0.85, maxDimension: MaxDimension.original, staging: staging
        )

        // The second conversion must not overwrite the first one's output.
        #expect(first.fileURL != second.fileURL)
        let firstData = try Data(contentsOf: first.fileURL)
        let secondData = try Data(contentsOf: second.fileURL)
        #expect(firstData != secondData)
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

    @Test func diffTreatsCollapsedDuplicateAssetsAsSynced() {
        // Two byte-identical Photos assets dedup to one record — neither id
        // may be reported as "added" or the album gets flagged forever.
        let collapsed = makeImage(sha: "dup", phId: "id-1")
        collapsed.trackPHAsset("id-2")

        let parts = PhotosLibraryMonitor.computeDeltaParts(
            photoIds: ["id-1", "id-2"],
            catalogImages: [collapsed]
        )

        #expect(parts.addedIds.isEmpty)
        #expect(parts.removed.isEmpty)
        #expect(parts.untrackable.isEmpty)
    }

    @Test func diffKeepsRecordWhileAnyTrackedAssetRemains() {
        let collapsed = makeImage(sha: "dup", phId: "id-1")
        collapsed.trackPHAsset("id-2")

        let partial = PhotosLibraryMonitor.computeDeltaParts(
            photoIds: ["id-2"],
            catalogImages: [collapsed]
        )
        #expect(partial.removed.isEmpty)

        let gone = PhotosLibraryMonitor.computeDeltaParts(
            photoIds: [],
            catalogImages: [collapsed]
        )
        #expect(gone.removed.map(\.sha256) == ["dup"])
    }

    @Test func deltaCoreReturnsIndicesForRemovedAndUntrackable() {
        let parts = PhotosLibraryMonitor.computeDeltaCore(
            photoIds: ["id-a", "id-new"],
            imageAssetIds: [["id-a", "id-a2"], ["id-gone"], []]
        )
        #expect(parts.addedIds == ["id-new"])
        #expect(parts.removedIndices == [1])
        #expect(parts.untrackableIndices == [2])
    }

    @Test func deltaContentComparisonSkipsNoOpUpdates() {
        let record = makeImage(sha: "a", phId: "id-a")
        let first = AlbumDelta(added: [], removed: [record], untrackable: [], albumMissing: false)
        let same = AlbumDelta(added: [], removed: [record], untrackable: [], albumMissing: false)
        let different = AlbumDelta(added: [], removed: [], untrackable: [record], albumMissing: false)

        #expect(first.hasSameContent(as: same))
        #expect(!first.hasSameContent(as: different))
        #expect(!first.hasSameContent(as: AlbumDelta(added: [], removed: [record], untrackable: [], albumMissing: true)))
    }

    @Test func diffFoldsLegacyScalarIdIntoTracking() {
        // Records persisted before the multi-id field existed have only the
        // legacy scalar populated.
        let legacy = makeImage(sha: "old", phId: "id-legacy")
        legacy.phAssetLocalIdentifiers = []

        let parts = PhotosLibraryMonitor.computeDeltaParts(
            photoIds: ["id-legacy"],
            catalogImages: [legacy]
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
        image.albums = [album]
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
        image.albums = [album]
        context.insert(image)
        try context.save()

        #expect(album.photosAlbumLocalIdentifier == "PH-album-1")
        #expect(image.phAssetLocalIdentifier == "PH-asset-1")
        #expect(image.allPHAssetIdentifiers == ["PH-asset-1"])
    }

    @Test func trackPHAssetAccumulatesDistinctIds() {
        let image = ImageRecord(
            sha256: "x",
            filename: "x.jpg",
            sizeBytes: 1,
            phAssetLocalIdentifier: "id-1"
        )
        image.trackPHAsset("id-2")
        image.trackPHAsset("id-1")
        image.trackPHAsset("id-2")

        #expect(image.allPHAssetIdentifiers.sorted() == ["id-1", "id-2"])
        #expect(image.phAssetLocalIdentifier == "id-1")
    }

    @Test func multipleTrackedAssetIdsPersist() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ImageRecord.self, AlbumRecord.self, VolumeRecord.self,
            configurations: config
        )
        let context = container.mainContext

        let image = ImageRecord(
            sha256: "cafebabe",
            filename: "dup.jpg",
            sizeBytes: 1,
            phAssetLocalIdentifier: "PH-asset-1"
        )
        image.trackPHAsset("PH-asset-2")
        context.insert(image)
        try context.save()

        #expect(image.allPHAssetIdentifiers.sorted() == ["PH-asset-1", "PH-asset-2"])
    }
}

// MARK: - PipelineItem Filename Propagation (regression: 54fb0f3)
//
// The pipelined import converted images to JPEG/HEIC correctly but never
// propagated the converted filename to downstream stages, so records and volume
// copies kept the original extension (.HEIC) while containing converted bytes.
// `activeFilename` / `activeFileURL` are the accessors that fix carries; they are
// `nonisolated` computed properties on a plain Sendable struct, so they are
// directly testable without running the pipeline.

@Suite
@MainActor
struct PipelineItemTests {

    private func makeItem(originalFilename: String = "IMG_0001.HEIC") -> PipelineItem {
        PipelineItem(
            albumName: "Trip",
            importDate: Date(timeIntervalSince1970: 1_700_000_000),
            fileURL: URL(fileURLWithPath: "/tmp/staging/\(originalFilename)"),
            originalFilename: originalFilename,
            phAssetLocalIdentifier: nil
        )
    }

    @Test func activeFilenameFallsBackToOriginalWhenNoConversion() {
        let item = makeItem()
        #expect(item.activeFilename == "IMG_0001.HEIC")
        #expect(item.activeFileURL == item.fileURL)
    }

    @Test func activeFilenameUsesConvertedNameOnceConverted() {
        var item = makeItem()
        item.convertedFilename = "IMG_0001.jpg"
        item.convertedURL = URL(fileURLWithPath: "/tmp/staging/converted/abc/IMG_0001.jpg")

        // The exact regression: downstream stages must see the .jpg name, not .HEIC.
        #expect(item.activeFilename == "IMG_0001.jpg")
        #expect(item.activeFileURL.lastPathComponent == "IMG_0001.jpg")
    }

    @Test func activeFileURLPrefersEncryptedOverConvertedOverOriginal() {
        var item = makeItem()
        #expect(item.activeFileURL.path == "/tmp/staging/IMG_0001.HEIC")

        item.convertedURL = URL(fileURLWithPath: "/tmp/staging/converted/abc/IMG_0001.jpg")
        #expect(item.activeFileURL.path == "/tmp/staging/converted/abc/IMG_0001.jpg")

        item.encryptedURL = URL(fileURLWithPath: "/tmp/staging/encrypted/IMG_0001.jpg.enc")
        #expect(item.activeFileURL.path == "/tmp/staging/encrypted/IMG_0001.jpg.enc")
    }

    @Test func encryptionDoesNotDisturbTheStoredFilename() {
        // Conversion + encryption together is the combination that made records
        // disagree with the bytes on disk: the name must stay the converted one
        // while the URL points at the ciphertext.
        var item = makeItem()
        item.convertedFilename = "IMG_0001.jpg"
        item.convertedURL = URL(fileURLWithPath: "/tmp/staging/converted/abc/IMG_0001.jpg")
        item.encryptedURL = URL(fileURLWithPath: "/tmp/staging/encrypted/IMG_0001.jpg.enc")

        #expect(item.activeFilename == "IMG_0001.jpg")
        #expect(item.activeFileURL.lastPathComponent == "IMG_0001.jpg.enc")
    }

}

// MARK: - Single-Image PAR2 Cleanup (regression: b97ed6d)
//
// Single-image deletion removed `<name>.par2` but left every `<name>.vol0+N.par2`
// behind, so orphan recovery volumes accumulated on the volume forever. The
// existing `deleteRemovesPAR2Companion` cannot see this: it deletes the whole
// album directory and asserts the directory is gone.

@Suite
@MainActor
struct SingleImagePAR2DeletionTests {

    private func input(for spec: TestFixtures.FileSpec, par2Filename: String) -> DeletionService.ImageDeletionInput {
        DeletionService.ImageDeletionInput(
            sha256: spec.sha256,
            filename: spec.name,
            par2Filename: par2Filename,
            b2FileId: nil,
            storageLocations: [],
            albumPath: spec.albumPath
        )
    }

    @Test func singleImageDeletionRemovesPAR2IndexAndVolumeFiles() async throws {
        let fm = FileManager.default
        let root = try TestFixtures.materializeVolumeWithPAR2(label: "single-par2")
        defer { try? fm.removeItem(at: root) }

        let vacation = TestFixtures.files(inAlbum: "Vacation")
        let target = vacation[0]
        let albumDir = root.appendingPathComponent(target.albumPath, isDirectory: true)

        // Precondition: PAR2 generation really did produce volume files here.
        let before = RedundancyService.companionFiles(forIndex: target.par2Name, in: albumDir)
        #expect(before.contains { $0.lastPathComponent.contains(".vol") })

        let result = await DeletionService().deleteImageFiles(
            images: [input(for: target, par2Filename: target.par2Name)],
            mountedVolumes: [("vol-1", root)],
            b2Credentials: nil,
            progress: DeletionProgress(),
            entireAlbum: false
        )

        // The image itself is the only thing counted; PAR2 companions go with it.
        #expect(result.volumeFilesRemoved == 1)
        #expect(!fm.fileExists(atPath: albumDir.appendingPathComponent(target.name).path))

        let leftovers = RedundancyService.companionFiles(forIndex: target.par2Name, in: albumDir)
        #expect(leftovers.isEmpty)

        // Nothing named `<target>.vol*.par2` may survive anywhere in the album.
        let remaining = (try? fm.contentsOfDirectory(atPath: albumDir.path)) ?? []
        #expect(!remaining.contains { $0.hasPrefix("\(target.name).vol") })
    }

    @Test func singleImageDeletionLeavesSiblingPAR2SetsIntact() async throws {
        let fm = FileManager.default
        let root = try TestFixtures.materializeVolumeWithPAR2(label: "single-par2-siblings")
        defer { try? fm.removeItem(at: root) }

        let vacation = TestFixtures.files(inAlbum: "Vacation")
        let target = vacation[0]
        let survivor = vacation[1]
        let albumDir = root.appendingPathComponent(target.albumPath, isDirectory: true)

        let survivorBefore = Set(
            RedundancyService.companionFiles(forIndex: survivor.par2Name, in: albumDir)
                .map(\.lastPathComponent)
        )
        #expect(!survivorBefore.isEmpty)

        _ = await DeletionService().deleteImageFiles(
            images: [input(for: target, par2Filename: target.par2Name)],
            mountedVolumes: [("vol-1", root)],
            b2Credentials: nil,
            progress: DeletionProgress(),
            entireAlbum: false
        )

        #expect(fm.fileExists(atPath: albumDir.appendingPathComponent(survivor.name).path))
        let survivorAfter = Set(
            RedundancyService.companionFiles(forIndex: survivor.par2Name, in: albumDir)
                .map(\.lastPathComponent)
        )
        #expect(survivorAfter == survivorBefore)
    }

    @Test func deletionDerivesPAR2NameWhenRecordCarriesNone() async throws {
        // A re-synced "second copy" record never had par2Filename populated (the
        // PAR2 stage skips duplicates). Before the fix the empty string produced
        // no companion lookup at all, orphaning the whole recovery set.
        let fm = FileManager.default
        let root = try TestFixtures.materializeVolumeWithPAR2(label: "single-par2-derived")
        defer { try? fm.removeItem(at: root) }

        let target = TestFixtures.files(inAlbum: "Nature")[0]
        let albumDir = root.appendingPathComponent(target.albumPath, isDirectory: true)

        _ = await DeletionService().deleteImageFiles(
            images: [input(for: target, par2Filename: "")],
            mountedVolumes: [("vol-1", root)],
            b2Credentials: nil,
            progress: DeletionProgress(),
            entireAlbum: false
        )

        #expect(!fm.fileExists(atPath: albumDir.appendingPathComponent(target.name).path))
        let leftovers = RedundancyService.companionFiles(forIndex: target.par2Name, in: albumDir)
        #expect(leftovers.isEmpty)
    }
}

// MARK: - Import Progress Bounds (regression: 5233888, 12632f7)
//
// 5233888: `filesCataloged` was not reset between albums, so a later, smaller
// album drove the bar past 100%. 12632f7: a Photos re-sync removal was labelled
// "Importing from Photos" with an indeterminate bar.

@Suite
@MainActor
struct ImportProgressBoundsTests {

    @Test func fractionNeverExceedsOneWhenCatalogedCountLeaksAcrossAlbums() {
        let progress = PhotosImportProgress()
        progress.phase = .hashing
        // Album A finished with 20 cataloged; album B has only 5 files.
        progress.totalFiles = 5
        progress.filesCataloged = 20

        // Uncapped this is 0.1 + (20/5)*0.9 = 3.7 — the overshoot users saw.
        #expect(progress.fraction <= 1.0)
        #expect(progress.fraction >= 0.0)
    }

    // The clamp above is a backstop, not the fix: it turns "the bar reads 370%"
    // into "the bar pins at 100% for the rest of the run", which is equally wrong.
    // The actual fix is `beginAlbum()` clearing the per-album counters. These two
    // tests pin the *expected* fraction through the real run/album sequence, so
    // dropping a reset fails them instead of being swallowed by the clamp.

    @Test func aSmallerSecondAlbumReportsItsOwnProgressRatherThanTheFirstAlbumsCount() {
        let progress = PhotosImportProgress()
        progress.beginRun(globalTotalFiles: 25)

        // Album A: 20 files, imported to completion. The pipeline *increments*
        // `filesCataloged` per file, so these tests do too — assigning it would
        // paper over exactly the leak under test.
        progress.beginAlbum()
        progress.totalFiles = 20
        progress.phase = .hashing
        for _ in 0..<20 { progress.filesCataloged += 1 }
        progress.finishAlbum()

        // Album B: only 5 files, 3 of them cataloged so far.
        progress.beginAlbum()
        progress.totalFiles = 5
        progress.phase = .hashing
        for _ in 0..<3 { progress.filesCataloged += 1 }

        // 20/25 banked, plus album B's own 0.1 + (3/5)*0.9 = 0.64 over its 5/25
        // share. Without the reset `filesCataloged` is still 20 and album B reads
        // a full 1.0, pushing this to exactly 1.0.
        #expect(abs(progress.fraction - 0.928) < 0.001)
    }

    @Test func aSingleAlbumRunIsNotWeightedByAnEarlierMultiAlbumRun() {
        let progress = PhotosImportProgress()

        // A three-album run in this sheet, carried to completion.
        progress.beginRun(globalTotalFiles: 100)
        progress.beginAlbum()
        progress.totalFiles = 100
        progress.phase = .hashing
        for _ in 0..<100 { progress.filesCataloged += 1 }
        progress.finishAlbum()
        #expect(progress.fraction == 1.0)

        // The user goes back and imports a single album without dismissing the
        // sheet. `progress` is the same object, so the old globals have to go.
        progress.beginRun(globalTotalFiles: 0)
        progress.beginAlbum()
        progress.totalFiles = 10
        progress.phase = .hashing
        for _ in 0..<5 { progress.filesCataloged += 1 }

        // 0.1 + (5/10)*0.9. Leaving the globals set pins this at 1.0 instead.
        #expect(abs(progress.fraction - 0.55) < 0.001)
    }

    @Test func fractionStaysInRangeAcrossPhasesAndCounts() {
        let phases: [ImportPhase] = [.importing, .removing, .hashing, .encrypting,
                                     .par2, .copying, .uploading, .cataloging, .complete]
        for phase in phases {
            for total in [1, 5, 20] {
                for done in [0, 1, total, total * 4] {
                    let progress = PhotosImportProgress()
                    progress.phase = phase
                    progress.totalFiles = total
                    progress.currentFile = done
                    progress.filesCataloged = done
                    let f = progress.fraction
                    #expect(f >= 0.0)
                    #expect(f <= 1.0)
                }
            }
        }
    }

    @Test func globalFractionStaysInRangeWhenAlbumOvershoots() {
        let progress = PhotosImportProgress()
        progress.phase = .hashing
        progress.globalTotalFiles = 100
        progress.completedAlbumFiles = 95
        progress.totalFiles = 5
        progress.filesCataloged = 40

        #expect(progress.fraction <= 1.0)
    }

    @Test func betweenAlbumsFractionIsClampedAndOtherwiseReportsTheGlobalShare() {
        // Between albums `totalFiles` is 0, so `fraction` takes the global-only
        // exit. That branch reads `completedAlbumFiles` — the other counter the
        // multi-album path accumulates by hand — so it needs the same bound as the
        // per-album path, not an unclamped division.
        let overshot = PhotosImportProgress()
        overshot.globalTotalFiles = 100
        overshot.completedAlbumFiles = 140

        #expect(overshot.fraction <= 1.0)
        #expect(overshot.fraction >= 0.0)

        // Clamping must not flatten the ordinary case: a real between-albums
        // position still reports the share already finished.
        let midway = PhotosImportProgress()
        midway.globalTotalFiles = 100
        midway.completedAlbumFiles = 40
        #expect(abs(midway.fraction - 0.4) < 0.001)

        // No totals at all is still a determinate zero, not NaN.
        #expect(PhotosImportProgress().fraction == 0)
    }

    /// The two per-phase weights the rest of this suite only bounds-checks. Import
    /// is deliberately squeezed into a flat 10% band because fetching from Photos
    /// is a small share of the work, and `.complete` must read exactly full rather
    /// than "whatever the counters happened to reach".
    @Test func importPhaseOccupiesTheFirstTenthAndCompleteReadsFull() {
        let importing = PhotosImportProgress()
        importing.totalFiles = 20
        importing.phase = .importing
        importing.currentFile = 10
        // (10/20) * 0.1 — halfway through the fetch is 5% of the run, not 50%.
        #expect(abs(importing.fraction - 0.05) < 0.001)

        let done = PhotosImportProgress()
        done.totalFiles = 5
        done.phase = .complete
        #expect(done.fraction == 1.0)
    }

    @Test func removalPhaseIsLabelledAndDeterminate() {
        // The removal pass must not read as an import, and it must advance a real
        // bar rather than sitting in the import phase's flat 10% band.
        #expect(ImportPhase.removing.rawValue == "Removing items")
        #expect(ImportPhase.removing.rawValue != ImportPhase.importing.rawValue)

        let progress = PhotosImportProgress()
        progress.phase = .removing
        progress.totalFiles = 4
        progress.currentFile = 2
        #expect(abs(progress.fraction - 0.5) < 0.001)
        #expect(progress.displayLabel == "Removing items")
    }
}

// MARK: - Bookmark Refresh (regression: 25a3a7c)
//
// Stale bookmarks threw instead of refreshing, so external volumes became
// inaccessible after a reboot. `resolveAccessAndRefresh` is the API that fix
// introduced.
//
// These assert unconditionally. An earlier version skipped on a failed
// `createBookmark` — on the theory that security-scoped bookmarks need the
// app-sandbox entitlement and only `xcodebuild test` supplies it — but that was
// wrong in both directions: `.withSecurityScope` bookmarks are created and
// resolved fine in an *unsandboxed* process (so the skip never fired), and CI's
// xcodebuild run passes CODE_SIGNING_ALLOWED=NO, so no entitlement is applied
// there either. The net effect of the skip would have been to turn these into
// silent no-ops the moment bookmarking did start failing — exactly when the
// 25a3a7c regression would need guarding. Let a failure be a failure.

@Suite
@MainActor
struct BookmarkResolverTests {

    private func makeScratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func resolveRoundTripsAFreshBookmark() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let data = try BookmarkResolver.createBookmark(for: dir)

        let (url, isStale) = try BookmarkResolver.resolve(data)
        #expect(url.resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path)
        #expect(isStale == false)
    }

    @Test func refreshReturnsNoNewBookmarkWhenNotStale() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let data = try BookmarkResolver.createBookmark(for: dir)
        let (url, refreshed) = try BookmarkResolver.resolveAccessAndRefresh(data)
        defer { url.stopAccessingSecurityScopedResource() }

        // A fresh bookmark is not stale, so there is nothing to write back.
        #expect(refreshed == nil)
    }

    @Test func corruptBookmarkDataStillThrows() {
        // The fix must silently refresh *stale* bookmarks without also swallowing
        // genuinely unusable ones.
        let garbage = Data(repeating: 0x7F, count: 64)
        #expect(throws: Error.self) {
            _ = try BookmarkResolver.resolve(garbage)
        }
    }
}

// MARK: - SwiftData Hydration (regression: 8cef649, b151c71, 1da8a89, 6dd8ad4)
//
// 8cef649: restore wrote catalog.json but never hydrated SwiftData, so the UI
// stayed empty under a "restored successfully" message.
// b151c71: performSync() merged and saved but never hydrated, so a second Mac
// showed an empty library.
// 1da8a89: launch hydration didn't rebuild when the store's count disagreed with
// the catalog, so a reset store never repopulated.
// 6dd8ad4: hydration fetched per image, making it O(N²) and hanging the main
// thread for seconds per sync cycle.

@Suite
@MainActor
struct HydrationTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ImageRecord.self, AlbumRecord.self, VolumeRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeCatalog(
        albums: [String: [CatalogImage]],
        year: String = "2026",
        month: String = "07",
        day: String = "20",
        addedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        deletions: [CatalogTombstone]? = nil
    ) -> Catalog {
        var catalogAlbums: [String: CatalogAlbum] = [:]
        for (name, images) in albums {
            catalogAlbums[name] = CatalogAlbum(addedAt: addedAt, images: images)
        }
        return Catalog(
            version: 1,
            lastUpdated: addedAt,
            years: [year: CatalogYear(months: [month: CatalogMonth(days: [day: CatalogDay(albums: catalogAlbums)])])],
            deletions: deletions
        )
    }

    private func image(_ sha: String, _ filename: String, addedAt: Date? = nil) -> CatalogImage {
        CatalogImage(
            filename: filename,
            sha256: sha,
            sizeBytes: 1234,
            par2Filename: "\(filename).par2",
            addedAt: addedAt
        )
    }

    @Test func hydrationPopulatesAnEmptyStoreFromTheCatalog() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let catalog = makeCatalog(albums: ["Trip": [image("aa", "one.heic"), image("bb", "two.heic")]])

        SyncCoordinator.hydrate(catalog: catalog, into: context)

        let albums = try context.fetch(FetchDescriptor<AlbumRecord>())
        #expect(albums.count == 1)
        #expect(albums.first?.name == "Trip")
        let imageCount = try context.fetchCount(FetchDescriptor<ImageRecord>())
        #expect(imageCount == 2)
    }

    @Test func hydrationIsAnIdempotentUpsert() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let catalog = makeCatalog(albums: ["Trip": [image("aa", "one.heic"), image("bb", "two.heic")]])

        SyncCoordinator.hydrate(catalog: catalog, into: context)
        SyncCoordinator.hydrate(catalog: catalog, into: context)
        SyncCoordinator.hydrate(catalog: catalog, into: context)

        // Re-running restore must not duplicate anything.
        let albumCount = try context.fetchCount(FetchDescriptor<AlbumRecord>())
        let imageCount = try context.fetchCount(FetchDescriptor<ImageRecord>())
        #expect(albumCount == 1)
        #expect(imageCount == 2)
    }

    @Test func hydrationPreservesLocalOnlyFieldsOnExistingRecords() throws {
        let container = try makeContainer()
        let context = container.mainContext

        // A record that already carries state the catalog does not describe.
        let existing = ImageRecord(
            sha256: "aa",
            filename: "stale.heic",
            sizeBytes: 1,
            storageLocations: [StorageLocation(volumeID: "vol-1", relativePath: "2026/07/20/Trip/one.heic")],
            thumbnailState: .generated,
            perceptualHash: Data([1, 2, 3, 4, 5, 6, 7, 8]),
            phAssetLocalIdentifier: "PH-1"
        )
        context.insert(existing)
        try context.save()

        SyncCoordinator.hydrate(
            catalog: makeCatalog(albums: ["Trip": [image("aa", "one.heic")]]),
            into: context
        )

        // Catalog-owned fields refresh...
        #expect(existing.filename == "one.heic")
        #expect(existing.sizeBytes == 1234)
        #expect(existing.albums.map(\.name) == ["Trip"])
        // ...local-only fields survive. 8cef649 states this invariant; nothing
        // enforced it until now.
        #expect(existing.storageLocations.count == 1)
        #expect(existing.thumbnailState == .generated)
        #expect(existing.perceptualHash?.count == 8)
        #expect(existing.allPHAssetIdentifiers == ["PH-1"])
    }

    @Test func staleDetectionFiresWhenTheStoreIsEmptyButTheCatalogIsNot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let catalog = makeCatalog(albums: ["Trip": [image("aa", "one.heic"), image("bb", "two.heic")]])

        // A lost/reset store that catalog.json already agrees with — the case that
        // never repopulated before 1da8a89.
        #expect(SyncCoordinator.isHydrationStale(catalog: catalog, context: context))

        SyncCoordinator.hydrate(catalog: catalog, into: context)
        #expect(!SyncCoordinator.isHydrationStale(catalog: catalog, context: context))
    }

    // Staleness has to be measured against the records `hydrate` produces, not
    // against the catalog's raw entry count. Where the two disagree the check can
    // never be satisfied, so every sync tick re-runs a full main-thread hydration
    // — the hang 6dd8ad4 removed, reintroduced through the back door. Both
    // catalogs below are perfectly ordinary, not corrupt.

    @Test func hydrationSettlesForAnImageFiledUnderTwoAlbums() throws {
        let container = try makeContainer()
        let context = container.mainContext
        // The same photo imported into two albums: 3 catalog entries, but
        // `ImageRecord.sha256` is unique so only 2 records can ever exist.
        let catalog = makeCatalog(albums: [
            "Trip": [image("aa", "one.heic"), image("bb", "two.heic")],
            "Beach": [image("aa", "one.heic")]
        ])

        #expect(SyncCoordinator.isHydrationStale(catalog: catalog, context: context))
        SyncCoordinator.hydrate(catalog: catalog, into: context)
        #expect(try context.fetchCount(FetchDescriptor<ImageRecord>()) == 2)
        #expect(!SyncCoordinator.isHydrationStale(catalog: catalog, context: context))
    }

    @Test func hydrationSettlesWhenTheCatalogHoldsUnsafeEntries() throws {
        let container = try makeContainer()
        let context = container.mainContext
        // The skipped entry is never a record, so counting it leaves the store
        // permanently "stale" no matter how many times hydration runs.
        let catalog = makeCatalog(albums: [
            "Trip": [image("aa", "ok.heic")],
            "../../escape": [image("bb", "bad.heic")]
        ])

        SyncCoordinator.hydrate(catalog: catalog, into: context)
        #expect(!SyncCoordinator.isHydrationStale(catalog: catalog, context: context))
    }

    @Test func aMultiAlbumImageIsFiledUnderEveryAlbumTheCatalogListsIt() throws {
        // The catalog files one sha under three albums. While `ImageRecord.album`
        // was to-one, hydration could only keep one of them — the walk assigned
        // and reassigned, so whichever album was visited last won and the other
        // two rendered the photo missing. #55 sorted the traversal, which made
        // the winner *stable* but no less wrong.
        let catalog = makeCatalog(albums: [
            "Alpha": [image("aa", "one.heic")],
            "Beach": [image("aa", "one.heic")],
            "Zulu": [image("aa", "one.heic")]
        ])

        for _ in 0..<5 {
            // Bind the container: `makeContainer().mainContext` alone lets the
            // container deallocate out from under the context.
            let container = try makeContainer()
            SyncCoordinator.hydrate(catalog: catalog, into: container.mainContext)

            // One record, because sha256 is unique...
            let records = try container.mainContext.fetch(FetchDescriptor<ImageRecord>())
            #expect(records.count == 1)
            // ...filed under all three albums, not one.
            let record = try #require(records.first)
            #expect(Set(record.albums.map(\.name)) == ["Alpha", "Beach", "Zulu"])

            // And each album shows it, which is what the sidebar and grid read.
            for album in try container.mainContext.fetch(FetchDescriptor<AlbumRecord>()) {
                #expect(album.images.count == 1, "\(album.name) rendered empty")
            }
        }
    }

    @Test func primaryAlbumIsStableAcrossHydrationsForPathDerivation() throws {
        // Membership is a set, but the bytes live at one path. `primaryAlbum` is
        // what the path-deriving call sites read, so it must not depend on
        // SwiftData's unspecified relationship ordering.
        let catalog = makeCatalog(albums: [
            "Zulu": [image("aa", "one.heic")],
            "Alpha": [image("aa", "one.heic")]
        ])

        var primaries: [String] = []
        for _ in 0..<5 {
            let container = try makeContainer()
            SyncCoordinator.hydrate(catalog: catalog, into: container.mainContext)
            let record = try #require(
                try container.mainContext.fetch(FetchDescriptor<ImageRecord>()).first
            )
            primaries.append(try #require(record.primaryAlbum?.name))
        }
        #expect(Set(primaries).count == 1, "primaryAlbum drifted between hydrations")
        #expect(primaries.first == "Alpha", "earliest by date-then-name should win")
    }

    @Test func hydrationSkipsEntriesWithTraversingPathComponents() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let catalog = makeCatalog(albums: [
            "Trip": [image("aa", "ok.heic")],
            "../../escape": [image("bb", "bad.heic")]
        ])
        SyncCoordinator.hydrate(catalog: catalog, into: context)

        let albums = try context.fetch(FetchDescriptor<AlbumRecord>())
        #expect(albums.count == 1)
        #expect(albums.first?.name == "Trip")
        let keptImages = try context.fetchCount(FetchDescriptor<ImageRecord>())
        #expect(keptImages == 1)
    }

    @Test func tombstonesRemoveRecordsThatPredateTheDeletion() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let added = Date(timeIntervalSince1970: 1_700_000_000)
        SyncCoordinator.hydrate(
            catalog: makeCatalog(albums: ["Trip": [image("aa", "one.heic", addedAt: added),
                                                  image("bb", "two.heic", addedAt: added)]]),
            into: context
        )
        let seeded = try context.fetchCount(FetchDescriptor<ImageRecord>())
        #expect(seeded == 2)

        // "bb" deleted on a peer, after the record was added.
        let tombstone = CatalogTombstone(
            year: "2026", month: "07", day: "20", album: "Trip",
            sha256: "bb", deletedAt: added.addingTimeInterval(60)
        )
        SyncCoordinator.hydrate(
            catalog: makeCatalog(albums: ["Trip": [image("aa", "one.heic", addedAt: added)]],
                                 deletions: [tombstone]),
            into: context
        )

        let remaining = try context.fetch(FetchDescriptor<ImageRecord>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.sha256 == "aa")
    }

    @Test func tombstonesDoNotDeleteARecordAddedAfterTheDeletion() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let deletedAt = Date(timeIntervalSince1970: 1_700_000_000)
        // An in-flight local import: the record exists and postdates the tombstone,
        // and the catalog no longer lists it. It must survive.
        let fresh = ImageRecord(
            sha256: "cc",
            filename: "fresh.heic",
            sizeBytes: 10,
            addedAt: deletedAt.addingTimeInterval(600)
        )
        context.insert(fresh)
        try context.save()

        let tombstone = CatalogTombstone(
            year: "2026", month: "07", day: "20", album: "Trip",
            sha256: "cc", deletedAt: deletedAt
        )
        SyncCoordinator.hydrate(
            catalog: makeCatalog(albums: ["Trip": [image("aa", "one.heic")]], deletions: [tombstone]),
            into: context
        )

        let shas = Set(try context.fetch(FetchDescriptor<ImageRecord>()).map(\.sha256))
        #expect(shas.contains("cc"))
    }

    @Test func hydratesALargeCatalogCorrectlyAndIdempotently() throws {
        // 6dd8ad4 replaced a per-image FetchDescriptor with two batch loads,
        // because the old shape evaluated a #Predicate against every registered
        // record for each lookup and hung the main thread for seconds per sync.
        //
        // This test does NOT assert the complexity. A ratio assertion was tried and
        // removed: hydrating 4x the catalog took 8.5x the time on CI even with the
        // batch-load fix in place (exponent ~1.5), because SwiftData's per-insert
        // cost grows with store size. A ratio test therefore cannot separate the
        // fixed shape from the quadratic one, and any threshold that passes today
        // either flakes or would wave a real regression through.
        //
        // What is left is a deterministic correctness check at a size where the old
        // per-image `FetchDescriptor` shape would be pathological — a genuine
        // reintroduction shows up as a job timeout rather than a clean assertion.
        // See TEST-PLAN.md "Remaining Automated Test TODOs": bug #30's
        // complexity is not fenced.
        let container = try makeContainer()
        let context = container.mainContext
        let images = (0..<2000).map { image(String(format: "%08x", $0), "img\($0).heic") }
        let catalog = makeCatalog(albums: ["Bulk": images])

        SyncCoordinator.hydrate(catalog: catalog, into: context)
        let hydrated = try context.fetchCount(FetchDescriptor<ImageRecord>())
        #expect(hydrated == 2000)

        // Re-hydrating a large catalog must stay an upsert, not a duplicate pass.
        SyncCoordinator.hydrate(catalog: catalog, into: context)
        let afterSecondPass = try context.fetchCount(FetchDescriptor<ImageRecord>())
        let albumCountAtScale = try context.fetchCount(FetchDescriptor<AlbumRecord>())
        #expect(afterSecondPass == 2000)
        #expect(albumCountAtScale == 1)
    }
}

// MARK: - Legacy Catalog Migration & Storage Resolution (regression: 2f44cfb)
//
// Apple rejected 1.0 under 2.4.5(i) (catalog inside the hidden sandbox container,
// container path shown in Settings) and 2.1(a) (import dead-ended with "No Storage
// Configured"). The fix moved the catalog to ~/Pictures/LumiVault, migrating any
// existing one on first launch, and modelled the library as a reserved volumeID so
// it behaves like any other storage target.

@Suite
@MainActor
struct CatalogMigrationTests {

    private func makeDirs() throws -> (legacy: URL, target: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-migrate-\(UUID().uuidString)", isDirectory: true)
        let legacy = base.appendingPathComponent("legacy", isDirectory: true)
        let target = base.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return (legacy, target)
    }

    @Test func migrationMovesTheCatalogAndItsRecoverySidecars() throws {
        let fm = FileManager.default
        let (legacy, target) = try makeDirs()
        defer { try? fm.removeItem(at: legacy.deletingLastPathComponent()) }

        for name in ["catalog.json", "catalog.json.sha256", "catalog.json.par2", "catalog.json.vol0+16.par2"] {
            try Data(name.utf8).write(to: legacy.appendingPathComponent(name))
        }
        // An unrelated neighbour must be left alone.
        try Data("keep".utf8).write(to: legacy.appendingPathComponent("notes.txt"))

        SyncCoordinator.migrateCatalog(from: legacy, to: target)

        for name in ["catalog.json", "catalog.json.sha256", "catalog.json.par2", "catalog.json.vol0+16.par2"] {
            #expect(fm.fileExists(atPath: target.appendingPathComponent(name).path))
            #expect(!fm.fileExists(atPath: legacy.appendingPathComponent(name).path))
        }
        #expect(fm.fileExists(atPath: legacy.appendingPathComponent("notes.txt").path))
    }

    @Test func migrationNeverClobbersAnExistingCatalog() throws {
        let fm = FileManager.default
        let (legacy, target) = try makeDirs()
        defer { try? fm.removeItem(at: legacy.deletingLastPathComponent()) }

        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("catalog.json"))
        try Data("current".utf8).write(to: target.appendingPathComponent("catalog.json"))

        SyncCoordinator.migrateCatalog(from: legacy, to: target)

        let contents = try String(contentsOf: target.appendingPathComponent("catalog.json"), encoding: .utf8)
        #expect(contents == "current")
        // The legacy copy stays put rather than being silently discarded.
        #expect(fm.fileExists(atPath: legacy.appendingPathComponent("catalog.json").path))
    }

    @Test func migrationIsANoOpWhenThereIsNothingToMove() throws {
        let fm = FileManager.default
        let (legacy, target) = try makeDirs()
        defer { try? fm.removeItem(at: legacy.deletingLastPathComponent()) }

        SyncCoordinator.migrateCatalog(from: legacy, to: target)
        #expect(((try? fm.contentsOfDirectory(atPath: target.path)) ?? []).isEmpty)
    }

    @Test func libraryResolvesAsAStorageTargetWithoutABookmark() {
        let location = StorageLocation(
            volumeID: Constants.Storage.libraryVolumeID,
            relativePath: "2026/07/20/Trip/one.heic"
        )
        let resolved = StorageResolver.resolveMount(for: location, volumes: [])
        #expect(resolved?.mountURL.path == Constants.Paths.libraryURL.path)
        // The library is reached via the Pictures entitlement, so there is no
        // security-scoped resource for the caller to release.
        #expect(resolved?.securityScoped == false)
    }

    @Test func unknownVolumeDoesNotResolve() {
        let location = StorageLocation(volumeID: "not-a-registered-volume", relativePath: "x.heic")
        #expect(StorageResolver.resolveMount(for: location, volumes: []) == nil)
    }

    @Test func librarySnapshotAndMountedPairAgreeOnOnePath() {
        let snapshot = StorageResolver.librarySnapshot()
        let mounted = StorageResolver.libraryMounted()
        #expect(snapshot.volumeID == Constants.Storage.libraryVolumeID)
        #expect(mounted.volumeID == Constants.Storage.libraryVolumeID)
        #expect(snapshot.mountURL.path == mounted.mountURL.path)
        #expect(snapshot.mountURL.path == Constants.Paths.libraryURL.path)
    }
}

// MARK: - HEIC Encoding & Alpha Stripping (regression: b428117, 25a3a7c)
//
// b428117: CIImage-based HEIC encoding silently failed, so files configured for
// HEIC were left as JPG with no error surfaced. 25a3a7c: RGBA sources were encoded
// without stripping alpha, producing corrupt JPEG/HEIC output. Existing conversion
// tests only cover the JPEG path from an opaque source.

@Suite
@MainActor
struct ImageConversionFormatTests {

    private func convert(
        sourceName: String,
        makeSource: (URL) throws -> Void,
        format: ImageFormat
    ) throws -> URL {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("lumivault-fmt-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let sourceURL = tmpDir.appendingPathComponent(sourceName)
        try makeSource(sourceURL)

        let staging = tmpDir.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let asset = ImportedAsset(fileURL: sourceURL, originalFilename: sourceName, creationDate: nil)
        let result = ImageConversionService.convertImage(
            asset: asset, format: format, quality: 0.85,
            maxDimension: MaxDimension.original, staging: staging
        )
        return result.fileURL
    }

    @Test func heicConversionProducesARealHEICFile() throws {
        let output = try convert(
            sourceName: "photo.jpg",
            makeSource: { try TestFixtures.createTinyJPEG(at: $0, width: 32, height: 32) },
            format: ImageFormat.heic
        )

        #expect(output.pathExtension == "heic")
        // The silent failure in b428117 left the *original* bytes in place, so the
        // decoded container type is the assertion that actually catches it.
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect((CGImageSourceGetType(source) as String?) == "public.heic")
        #expect(CGImageSourceGetCount(source) >= 1)
    }

    @Test func jpegConversionStripsAlphaFromAnRGBASource() throws {
        let output = try convert(
            sourceName: "transparent.png",
            makeSource: { try TestFixtures.createTransparentPNG(at: $0, width: 32, height: 32) },
            format: ImageFormat.jpeg
        )

        #expect(output.pathExtension == "jpg")
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let cgImage = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(cgImage.alphaInfo == .none || cgImage.alphaInfo == .noneSkipLast
                || cgImage.alphaInfo == .noneSkipFirst)
    }

    @Test func heicConversionStripsAlphaFromAnRGBASource() throws {
        let output = try convert(
            sourceName: "transparent.png",
            makeSource: { try TestFixtures.createTransparentPNG(at: $0, width: 32, height: 32) },
            format: ImageFormat.heic
        )

        #expect(output.pathExtension == "heic")
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let cgImage = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(cgImage.alphaInfo == .none || cgImage.alphaInfo == .noneSkipLast
                || cgImage.alphaInfo == .noneSkipFirst)
    }
}

// MARK: - Cancellation Drains vs Breaks (regression: abe7b51)
//
// Every pipeline phase used `continue` on cancellation, which drained the channel's
// buffer instead of exiting — so cancelling an import kept working through
// everything already queued. The fix changed them to `break`.
//
// The contract that makes `break` load-bearing is asserted here: `cancel()`
// terminates the stream but does NOT discard items already yielded. If someone
// "fixes" cancel() to drop the backlog, these tests document why the consumer-side
// break still has to exist.

@Suite
struct ChannelCancellationDrainTests {

    @Test func cancelDoesNotDiscardAlreadyBufferedItems() async {
        let channel = AsyncChannel<Int>(bufferSize: 8)
        for i in 0..<5 { await channel.send(i) }
        await channel.cancel()

        // A consumer that keeps looping still sees the backlog — this is exactly
        // what `continue` did.
        var drained = 0
        for await _ in channel.stream { drained += 1 }
        #expect(drained == 5)
    }

    /// Drives a real pipeline stage, not a copy of one: `runConversionStage` has
    /// the same `for await … if Task.isCancelled { break }` body as the other
    /// seven, so reverting that `break` to `continue` fails this test.
    ///
    /// `continue` and `break` differ in exactly one observable: how much of the
    /// input channel the stage dequeues before returning. Nothing else in the
    /// body runs — the cancellation check sits above the work — so the assertion
    /// is on what is *left* in the channel afterwards. The whole backlog is
    /// buffered up front so `next()` never suspends: a suspended `next()` returns
    /// nil on a cancelled task, which would end the loop on its own and mask the
    /// difference. No sleeps, no wall-clock assumptions.
    @Test func cancelledStageStopsConsumingInsteadOfDrainingTheBacklog() async throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let backlog = 6
        // Buffer everything up front, so no send blocks and no dequeue suspends.
        let inputCh = AsyncChannel<PipelineItem>(bufferSize: backlog + 2)
        let outputCh = AsyncChannel<PipelineItem>(bufferSize: backlog + 2)

        // Videos take the stage's pass-through path, so no image codec runs and
        // the shape of the loop is all that is under test.
        for index in 0..<backlog {
            await inputCh.send(PipelineItem(
                albumName: "Cancel",
                importDate: Date(timeIntervalSince1970: 1_700_000_000),
                fileURL: staging.appendingPathComponent("clip-\(index).mov"),
                originalFilename: "clip-\(index).mov",
                phAssetLocalIdentifier: nil,
                mediaType: .video
            ))
        }
        inputCh.finish()

        let coordinator = await PipelinedImportCoordinator(
            catalogService: CatalogService(),
            encryptionService: EncryptionService()
        )
        let progress = await PhotosImportProgress()

        // Cancel before the stage starts, so the very first iteration is the one
        // that has to exit: `Task.isCancelled` is already true at the check.
        let stage = Task {
            await coordinator.runConversionStage(
                inputCh: inputCh,
                outputCh: outputCh,
                settings: ImportSettings(albumName: "Cancel", year: "2026", month: "07", day: "20"),
                staging: staging,
                progress: progress
            )
        }
        stage.cancel()
        await stage.value

        // The stage dequeued one item and left the rest. With `continue` it walks
        // the whole backlog before the stream ends and this is 0 — which is the
        // "cancelling an import keeps processing everything queued" bug itself.
        var remaining = 0
        for await _ in inputCh.stream { remaining += 1 }
        #expect(remaining == backlog - 1)

        // A cancelled stage must not forward work downstream either. The stage's
        // own `defer` finished `outputCh`, so this iteration terminates.
        var forwarded = 0
        for await _ in outputCh.stream { forwarded += 1 }
        #expect(forwarded == 0)
    }
}

// MARK: - Photos Stall Policy (regression: c4cf7ee, 5233888, aedc03b, 1da8a89)
//
// The watchdog around PHAssetResourceManager is untestable as a whole — it needs a
// live continuation and assetsd — but every decision it makes is arithmetic, now
// isolated in StallPolicy.

@Suite
struct StallPolicyTests {

    @Test func thresholdsDoubleAcrossTenAttempts() {
        // 1, 2, 4 … 512 seconds. Before 5233888 a stall waited on a flat 10-minute
        // hard skip instead of retrying.
        let expected: [TimeInterval] = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512]
        #expect(StallPolicy.maxAttempts == expected.count)
        for (attempt, seconds) in expected.enumerated() {
            #expect(StallPolicy.threshold(forAttempt: attempt) == seconds)
        }
    }

    @Test func flowingBytesReportHealthy() {
        #expect(StallPolicy.decide(attempt: 0, idleFor: 0, elapsedForAsset: 30) == .healthy)
        // Just under half the threshold is still healthy.
        #expect(StallPolicy.decide(attempt: 3, idleFor: 3.9, elapsedForAsset: 60) == .healthy)
    }

    @Test func idlePastTheThresholdStalls() {
        #expect(StallPolicy.decide(attempt: 0, idleFor: 1.0, elapsedForAsset: 0) == .stalled)
        #expect(StallPolicy.decide(attempt: 2, idleFor: 4.5, elapsedForAsset: 99) == .stalled)
    }

    @Test func slowMessageIsSuppressedForTheFirstFiveSeconds() {
        // aedc03b: attempt 0's threshold is 1s, so the message would otherwise fire
        // after 0.5s of idling and vanish again when attempt 1 succeeded.
        #expect(StallPolicy.decide(attempt: 0, idleFor: 0.6, elapsedForAsset: 0.6) == .quiet)
        #expect(StallPolicy.decide(attempt: 0, idleFor: 0.6, elapsedForAsset: 4.99) == .quiet)

        // Past the delay it surfaces, with a countdown.
        #expect(StallPolicy.decide(attempt: 0, idleFor: 0.6, elapsedForAsset: 5.0)
                == .slow(secondsUntilRetry: 1))
    }

    @Test func countdownReportsWholeSecondsRemainingAndNeverGoesNegative() {
        // attempt 3 → 8s threshold; idle 5s → 3s left.
        #expect(StallPolicy.decide(attempt: 3, idleFor: 5, elapsedForAsset: 30)
                == .slow(secondsUntilRetry: 3))
        // Fractional remainders round up so the countdown never displays 0 while
        // the retry has not fired.
        #expect(StallPolicy.decide(attempt: 3, idleFor: 7.2, elapsedForAsset: 30)
                == .slow(secondsUntilRetry: 1))

        for idle in stride(from: 4.05, to: 8.0, by: 0.25) {
            guard case .slow(let seconds) = StallPolicy.decide(
                attempt: 3, idleFor: idle, elapsedForAsset: 30
            ) else {
                Issue.record("Expected .slow at idle \(idle)")
                continue
            }
            #expect(seconds >= 0)
            #expect(seconds <= 8)
        }
    }

    @Test func laterAttemptsTolerateLongerIdlePeriods() {
        // The same 40s idle is a stall early on and merely slow later — that is what
        // lets a genuinely slow iCloud download finish instead of being killed.
        // attempt 2 → 4s threshold; attempt 6 → 64s threshold (half = 32s).
        #expect(StallPolicy.decide(attempt: 2, idleFor: 40, elapsedForAsset: 60) == .stalled)
        #expect(StallPolicy.decide(attempt: 6, idleFor: 40, elapsedForAsset: 60)
                == .slow(secondsUntilRetry: 24))
        // Still comfortably healthy at the same attempt with a shorter idle.
        #expect(StallPolicy.decide(attempt: 6, idleFor: 30, elapsedForAsset: 60) == .healthy)
    }
}

// MARK: - Thumbnail Cache Location (regression: bf00a05)
//
// Thumbnails lived in the sandboxed Caches directory, which macOS purges under disk
// pressure, so the grid went blank and nothing regenerated them.

@Suite
struct ThumbnailCacheTests {

    private func makeScratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-thumbs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func defaultCacheRootLivesInApplicationSupportNotCaches() {
        let path = ThumbnailService.defaultCacheRoot.path
        #expect(path.contains("Application Support"))
        // The exact regression: a Caches path is purgeable.
        #expect(!path.contains("/Caches/"))
        #expect(ThumbnailService.defaultCacheRoot.lastPathComponent == "Thumbnails")
    }

    @Test func thumbnailsAreWrittenUnderTheShaKeyedLayout() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.jpg")
        try TestFixtures.createTinyJPEG(at: sourceURL, width: 64, height: 64)

        let sha = "abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234"
        let service = ThumbnailService(cacheRoot: root.appendingPathComponent("Thumbnails"))
        try await service.generateThumbnail(for: sourceURL, sha256: sha)

        for size in [ThumbnailSize.grid, ThumbnailSize.list] {
            let location = await service.cacheLocation(for: sha, size: size)
            #expect(FileManager.default.fileExists(atPath: location.path))
            // Sharded by size then by the first two hash characters.
            #expect(location.deletingLastPathComponent().lastPathComponent == "ab")
            #expect(location.deletingLastPathComponent().deletingLastPathComponent()
                        .lastPathComponent == "\(size.rawValue)")
        }
    }

    @Test func missingThumbnailReadsAsNilSoCallersCanRegenerate() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let service = ThumbnailService(cacheRoot: root.appendingPathComponent("Thumbnails"))
        let missing = await service.thumbnail(
            for: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            size: .grid
        )
        // A purged cache must read as a miss, not a crash — that miss is what
        // drives regeneration from the source volume.
        #expect(missing == nil)
    }

    @Test func removingThumbnailsClearsBothSizesFromDisk() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.jpg")
        try TestFixtures.createTinyJPEG(at: sourceURL, width: 64, height: 64)

        let sha = "beef0000beef0000beef0000beef0000beef0000beef0000beef0000beef0000"
        let service = ThumbnailService(cacheRoot: root.appendingPathComponent("Thumbnails"))
        try await service.generateThumbnail(for: sourceURL, sha256: sha)
        await service.removeThumbnails(for: sha)

        for size in [ThumbnailSize.grid, ThumbnailSize.list] {
            let location = await service.cacheLocation(for: sha, size: size)
            #expect(!FileManager.default.fileExists(atPath: location.path))
        }
    }
}

// MARK: - Pipeline Phase Routing (regression guard for the wiring itself)
//
// Each stage forwards to the next *enabled* stage, so a disabled phase has to be
// skipped over rather than fed. Expressed inline this was a nested ternary chain
// per stage; a mistake there sends items into a channel nobody consumes, and the
// import wedges on backpressure rather than failing.

@Suite
struct PipelinePhaseRoutingTests {

    private func phases(encryption: Bool = false, par2: Bool = false,
                        copy: Bool = false, upload: Bool = false) -> PipelinePhases {
        PipelinePhases(encryption: encryption, par2: par2, copy: copy, upload: upload)
    }

    @Test func allPhasesEnabledFormsTheFullChain() {
        let p = phases(encryption: true, par2: true, copy: true, upload: true)
        #expect(p.next(after: .hashing) == .encryption)
        #expect(p.next(after: .encryption) == .par2)
        #expect(p.next(after: .par2) == .copy)
        #expect(p.next(after: .copy) == .upload)
        #expect(p.next(after: .upload) == .catalog)
    }

    @Test func noOptionalPhasesRoutesStraightToTheCatalogSink() {
        let p = phases()
        for stage in [PipelinePhases.Stage.hashing, .encryption, .par2, .copy, .upload] {
            #expect(p.next(after: stage) == .catalog)
        }
    }

    @Test func disabledPhasesAreSkippedOverNotFed() {
        // PAR2 + upload only: hashing must jump past encryption to par2, and par2
        // must jump past copy to upload.
        let p = phases(encryption: false, par2: true, copy: false, upload: true)
        #expect(p.next(after: .hashing) == .par2)
        #expect(p.next(after: .par2) == .upload)
        #expect(p.next(after: .upload) == .catalog)
        // Even though encryption and copy do not run, asking where they *would*
        // forward must still name a live stage — the coordinator computes all of
        // these unconditionally.
        #expect(p.next(after: .encryption) == .par2)
        #expect(p.next(after: .copy) == .upload)
    }

    @Test func routingNeverTargetsADisabledStage() {
        // Exhaustive over all 16 combinations: whatever a stage forwards to must
        // itself be enabled (or the always-on catalog sink).
        for mask in 0..<16 {
            let p = phases(
                encryption: mask & 1 != 0,
                par2: mask & 2 != 0,
                copy: mask & 4 != 0,
                upload: mask & 8 != 0
            )
            for stage in [PipelinePhases.Stage.hashing, .encryption, .par2, .copy, .upload] {
                let target = p.next(after: stage)
                #expect(p.isEnabled(target), "mask \(mask): \(stage) → disabled \(target)")
            }
        }
    }

    @Test func routingAlwaysMovesForwardAndTerminates() {
        // Following the chain from hashing must reach .catalog without revisiting a
        // stage — a cycle would deadlock the pipeline.
        for mask in 0..<16 {
            let p = phases(
                encryption: mask & 1 != 0,
                par2: mask & 2 != 0,
                copy: mask & 4 != 0,
                upload: mask & 8 != 0
            )
            var seen: [PipelinePhases.Stage] = []
            var stage = PipelinePhases.Stage.hashing
            while stage != .catalog {
                #expect(!seen.contains(stage), "mask \(mask): revisited \(stage)")
                seen.append(stage)
                stage = p.next(after: stage)
                if seen.count > 6 { break }
            }
            #expect(stage == .catalog, "mask \(mask): chain did not terminate")
        }
    }

    @Test func catalogIsTerminal() {
        #expect(phases(encryption: true, par2: true, copy: true, upload: true)
            .next(after: .catalog) == .catalog)
    }
}

// MARK: - Copy-Stage Mirroring (regression: 2f44cfb, 5568b41)
//
// `ensureFileMirrored` is what makes a re-run of an interrupted import cheap and
// what stops a truncated leftover from being trusted as a complete copy.

@Suite
struct EnsureFileMirroredTests {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func copiesWhenDestinationIsAbsent() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("a.bin")
        let dest = dir.appendingPathComponent("b.bin")
        try Data("payload".utf8).write(to: source)

        try PipelinedImportCoordinator.ensureFileMirrored(from: source, to: dest)
        let copied = try Data(contentsOf: dest)
        #expect(copied == Data("payload".utf8))
    }

    @Test func leavesAMatchingDestinationUntouched() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("a.bin")
        let dest = dir.appendingPathComponent("b.bin")
        try Data("12345".utf8).write(to: source)
        // Same size, different bytes: the size check is deliberately cheap, and a
        // same-size destination is trusted rather than re-copied.
        try Data("abcde".utf8).write(to: dest)

        try PipelinedImportCoordinator.ensureFileMirrored(from: source, to: dest)
        let untouched = try Data(contentsOf: dest)
        #expect(untouched == Data("abcde".utf8))
    }

    @Test func replacesATruncatedOrEmptyDestination() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("a.bin")
        try Data("full payload".utf8).write(to: source)

        // Partial leftover from an interrupted copy.
        let partial = dir.appendingPathComponent("partial.bin")
        try Data("full".utf8).write(to: partial)
        try PipelinedImportCoordinator.ensureFileMirrored(from: source, to: partial)
        let repaired = try Data(contentsOf: partial)
        #expect(repaired == Data("full payload".utf8))

        // A zero-byte file is never trusted, even against a zero-byte source.
        let empty = dir.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        try PipelinedImportCoordinator.ensureFileMirrored(from: source, to: empty)
        let filled = try Data(contentsOf: empty)
        #expect(filled == Data("full payload".utf8))
    }

    @Test func missingSourceThrows() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: Error.self) {
            try PipelinedImportCoordinator.ensureFileMirrored(
                from: dir.appendingPathComponent("nope.bin"),
                to: dir.appendingPathComponent("dest.bin")
            )
        }
    }
}

// MARK: - Replica Healing (regression: 5568b41)
//
// The heal pass restores a file missing from one storage target by copying it from
// a healthy sibling volume or re-downloading it from B2. Volume-to-volume healing
// is exercised here; the B2 source needs live credentials and stays manual.

@Suite
@MainActor
struct HealReplicasTests {

    private func snapshot(
        for spec: TestFixtures.FileSpec,
        volumeIDs: [String],
        isEncrypted: Bool = false,
        relativePathOverride: String? = nil
    ) -> ImageSnapshot {
        ImageSnapshot(
            sha256: spec.sha256,
            filename: spec.name,
            par2Filename: spec.par2Name,
            b2FileId: nil,
            storageLocations: volumeIDs.map {
                StorageLocation(
                    volumeID: $0,
                    relativePath: relativePathOverride ?? "\(spec.albumPath)/\(spec.name)"
                )
            },
            albumPath: spec.albumPath,
            isEncrypted: isEncrypted
        )
    }

    @Test func restoresAMissingFileFromASiblingVolume() async throws {
        let fm = FileManager.default
        let volA = try TestFixtures.materializeVolume(label: "heal-a")
        let volB = try TestFixtures.materializeVolume(label: "heal-b")
        defer {
            try? fm.removeItem(at: volA)
            try? fm.removeItem(at: volB)
        }

        let spec = TestFixtures.files[0]
        let missing = volA.appendingPathComponent("\(spec.albumPath)/\(spec.name)")
        try fm.removeItem(at: missing)
        #expect(!fm.fileExists(atPath: missing.path))

        let results = await ReconciliationService().healReplicas(
            discrepancies: [Discrepancy(sha256: spec.sha256, filename: spec.name,
                                        kind: .danglingLocation(volumeID: "vol-a"))],
            snapshots: [snapshot(for: spec, volumeIDs: ["vol-a", "vol-b"])],
            volumes: [
                VolumeSnapshot(volumeID: "vol-a", label: "A", mountURL: volA),
                VolumeSnapshot(volumeID: "vol-b", label: "B", mountURL: volB)
            ],
            b2Credentials: nil,
            progress: ReconciliationProgress()
        )

        #expect(results.count == 1)
        // `try #require`, not `results[0]`: an empty array must fail this one test,
        // not trap and take the whole in-process test run down with it.
        let result = try #require(results.first)
        guard case .restoredToVolume(let volumeID, let source) = result.outcome else {
            Issue.record("Expected a volume restore, got \(result.outcome)")
            return
        }
        #expect(volumeID == "vol-a")
        guard case .volume(let sourceID) = source else {
            Issue.record("Expected a sibling-volume source")
            return
        }
        #expect(sourceID == "vol-b")

        // The restored bytes must be the real thing, not a placeholder.
        #expect(fm.fileExists(atPath: missing.path))
        let restored = try Data(contentsOf: missing)
        #expect(restored == TestFixtures.content(for: spec))
    }

    @Test func reportsFailureWhenNoHealthySourceExists() async throws {
        let fm = FileManager.default
        let volA = try TestFixtures.materializeVolume(label: "heal-lonely")
        defer { try? fm.removeItem(at: volA) }

        let spec = TestFixtures.files[1]
        try fm.removeItem(at: volA.appendingPathComponent("\(spec.albumPath)/\(spec.name)"))

        let results = await ReconciliationService().healReplicas(
            discrepancies: [Discrepancy(sha256: spec.sha256, filename: spec.name,
                                        kind: .danglingLocation(volumeID: "vol-a"))],
            snapshots: [snapshot(for: spec, volumeIDs: ["vol-a"])],
            volumes: [VolumeSnapshot(volumeID: "vol-a", label: "A", mountURL: volA)],
            b2Credentials: nil,
            progress: ReconciliationProgress()
        )

        let result = try #require(results.first)
        guard case .failed(let reason) = result.outcome else {
            Issue.record("Expected a failure, got \(result.outcome)")
            return
        }
        // A discrepancy that cannot be healed must be reported, not silently dropped.
        #expect(!reason.isEmpty)
    }

    @Test func refusesToWriteOutsideTheTargetVolume() async throws {
        let fm = FileManager.default
        let volA = try TestFixtures.materializeVolume(label: "heal-traversal-a")
        let volB = try TestFixtures.materializeVolume(label: "heal-traversal-b")
        defer {
            try? fm.removeItem(at: volA)
            try? fm.removeItem(at: volB)
        }

        let spec = TestFixtures.files[2]
        let results = await ReconciliationService().healReplicas(
            discrepancies: [Discrepancy(sha256: spec.sha256, filename: spec.name,
                                        kind: .danglingLocation(volumeID: "vol-a"))],
            snapshots: [snapshot(for: spec, volumeIDs: ["vol-a", "vol-b"],
                                 relativePathOverride: "../../escaped.heic")],
            volumes: [
                VolumeSnapshot(volumeID: "vol-a", label: "A", mountURL: volA),
                VolumeSnapshot(volumeID: "vol-b", label: "B", mountURL: volB)
            ],
            b2Credentials: nil,
            progress: ReconciliationProgress()
        )

        guard case .failed = try #require(results.first).outcome else {
            Issue.record("A traversing relativePath must not be written")
            return
        }
        #expect(!fm.fileExists(atPath: volA.appendingPathComponent("../../escaped.heic").path))
    }

    @Test func healingIgnoresDiscrepancyKindsItCannotFix() async throws {
        let volA = try TestFixtures.materializeVolume(label: "heal-noop")
        defer { try? FileManager.default.removeItem(at: volA) }

        let spec = TestFixtures.files[3]
        let results = await ReconciliationService().healReplicas(
            discrepancies: [
                Discrepancy(sha256: spec.sha256, filename: spec.name,
                            kind: .orphanOnVolume(volumeID: "vol-a", path: "stray.heic"))
            ],
            snapshots: [snapshot(for: spec, volumeIDs: ["vol-a"])],
            volumes: [VolumeSnapshot(volumeID: "vol-a", label: "A", mountURL: volA)],
            b2Credentials: nil,
            progress: ReconciliationProgress()
        )
        // Orphans are a user decision (keep or delete), never something heal acts on.
        #expect(results.isEmpty)
    }
}
