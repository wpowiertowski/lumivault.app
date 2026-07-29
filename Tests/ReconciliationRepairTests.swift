import Testing
import Foundation
import CryptoKit
@testable import LumiVault

// MARK: - Corruption detection & auto-repair
//
// `verifyFileHashes` and `repairCorruptedFiles` decide whether a bit-rotted
// archive gets healed or silently left mangled — the app's core promise, and
// until now its least-covered path (ReconciliationService sat at 49.6%, with
// the repair strategy entirely untested).
//
// Neither needs B2 or an entitlement: both operate on real files under real
// volume roots, so a temp directory per volume is enough.

@Suite
@MainActor
struct ReconciliationRepairTests {

    /// Two volume roots plus helpers to plant good and corrupted copies.
    ///
    /// `@MainActor` because `ReconciliationProgress()`'s default values are
    /// MainActor-isolated under the app target's default isolation.
    @MainActor
    final class Fixture {
        let root: URL
        let volumeA: URL
        let volumeB: URL
        let albumPath = "2026/07/28/Trip"
        let progress = ReconciliationProgress()

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("lumivault-repair-\(UUID().uuidString)", isDirectory: true)
            volumeA = root.appendingPathComponent("volA", isDirectory: true)
            volumeB = root.appendingPathComponent("volB", isDirectory: true)
            for v in [volumeA, volumeB] {
                try FileManager.default.createDirectory(
                    at: v.appendingPathComponent(albumPath, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func albumDir(_ volume: URL) -> URL {
            volume.appendingPathComponent(albumPath, isDirectory: true)
        }

        @discardableResult
        func write(_ bytes: Data, named name: String, on volume: URL) throws -> URL {
            let url = albumDir(volume).appendingPathComponent(name)
            try bytes.write(to: url)
            return url
        }

        func volumeSnapshots() -> [VolumeSnapshot] {
            [
                VolumeSnapshot(volumeID: "vol-a", label: "A", mountURL: volumeA),
                VolumeSnapshot(volumeID: "vol-b", label: "B", mountURL: volumeB)
            ]
        }

        func location(_ volumeID: String, _ name: String) -> StorageLocation {
            StorageLocation(volumeID: volumeID, relativePath: "\(albumPath)/\(name)")
        }

        static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: - Detection

    @Test func verifyHashesFlagsARottedFileThatAnExistenceCheckWouldPass() async throws {
        let f = try Fixture()
        defer { f.cleanup() }

        let good = Data("the original bytes".utf8)
        let expected = Fixture.sha256(good)
        // Same filename, same place, different content — exactly what bit rot looks like.
        try f.write(Data("corrupted!".utf8), named: "photo.jpg", on: f.volumeA)

        let snapshot = ImageSnapshot(
            sha256: expected, filename: "photo.jpg", par2Filename: "", b2FileId: nil,
            storageLocations: [f.location("vol-a", "photo.jpg")], albumPath: f.albumPath
        )
        let service = ReconciliationService()

        // Without hash verification the file exists, so nothing is reported.
        let shallow = await service.reconcile(
            snapshots: [snapshot], volumes: f.volumeSnapshots(), b2Credentials: nil,
            verifyHashes: false, scanOrphans: false, progress: f.progress
        )
        #expect(shallow.discrepancies.isEmpty, "existence-only scan should not flag anything")

        // With it, the mismatch surfaces with both hashes.
        let deep = await service.reconcile(
            snapshots: [snapshot], volumes: f.volumeSnapshots(), b2Credentials: nil,
            verifyHashes: true, scanOrphans: false, progress: f.progress
        )
        let mismatches = deep.discrepancies.filter {
            if case .hashMismatch = $0.kind { return true }
            return false
        }
        #expect(mismatches.count == 1)
        if case .hashMismatch(let volumeID, let exp, let actual) = try #require(mismatches.first).kind {
            #expect(volumeID == "vol-a")
            #expect(exp == expected)
            #expect(actual != expected)
        }
    }

    @Test func verifyHashesLeavesAnIntactFileAlone() async throws {
        let f = try Fixture()
        defer { f.cleanup() }

        let good = Data("intact bytes".utf8)
        try f.write(good, named: "photo.jpg", on: f.volumeA)
        let snapshot = ImageSnapshot(
            sha256: Fixture.sha256(good), filename: "photo.jpg", par2Filename: "", b2FileId: nil,
            storageLocations: [f.location("vol-a", "photo.jpg")], albumPath: f.albumPath
        )

        let report = await ReconciliationService().reconcile(
            snapshots: [snapshot], volumes: f.volumeSnapshots(), b2Credentials: nil,
            verifyHashes: true, scanOrphans: false, progress: f.progress
        )
        #expect(report.discrepancies.isEmpty)
    }

    // MARK: - Repair strategy 1: healthy replica

    @Test func repairRestoresCorruptedBytesFromAHealthyReplicaOnAnotherVolume() async throws {
        let f = try Fixture()
        defer { f.cleanup() }

        let good = Data(repeating: 0xAB, count: 4096)
        let expected = Fixture.sha256(good)
        let corruptedURL = try f.write(Data(repeating: 0x00, count: 4096), named: "photo.jpg", on: f.volumeA)
        try f.write(good, named: "photo.jpg", on: f.volumeB)

        let snapshot = ImageSnapshot(
            sha256: expected, filename: "photo.jpg", par2Filename: "", b2FileId: nil,
            storageLocations: [f.location("vol-a", "photo.jpg"), f.location("vol-b", "photo.jpg")],
            albumPath: f.albumPath
        )
        let discrepancy = Discrepancy(
            sha256: expected, filename: "photo.jpg",
            kind: .hashMismatch(volumeID: "vol-a", expected: expected, actual: Fixture.sha256(Data(repeating: 0x00, count: 4096)))
        )

        let results = await ReconciliationService().repairCorruptedFiles(
            discrepancies: [discrepancy], snapshots: [snapshot],
            volumes: f.volumeSnapshots(), progress: f.progress
        )

        let result = try #require(results.first)
        guard case .copiedFromVolume(let source) = result.outcome else {
            Issue.record("expected .copiedFromVolume, got \(String(describing: result.outcome))")
            return
        }
        #expect(source == "vol-b")
        // The bytes on disk really changed — the outcome enum alone would not prove it.
        #expect(Fixture.sha256(try Data(contentsOf: corruptedURL)) == expected)
    }

    @Test func repairRefusesAReplicaThatIsItselfCorrupt() async throws {
        let f = try Fixture()
        defer { f.cleanup() }

        let expected = Fixture.sha256(Data(repeating: 0xAB, count: 2048))
        try f.write(Data(repeating: 0x00, count: 2048), named: "photo.jpg", on: f.volumeA)
        // Volume B has the file, but its bytes are wrong too.
        try f.write(Data(repeating: 0x11, count: 2048), named: "photo.jpg", on: f.volumeB)

        let snapshot = ImageSnapshot(
            sha256: expected, filename: "photo.jpg", par2Filename: "", b2FileId: nil,
            storageLocations: [f.location("vol-a", "photo.jpg"), f.location("vol-b", "photo.jpg")],
            albumPath: f.albumPath
        )
        let discrepancy = Discrepancy(
            sha256: expected, filename: "photo.jpg",
            kind: .hashMismatch(volumeID: "vol-a", expected: expected, actual: "whatever")
        )

        let results = await ReconciliationService().repairCorruptedFiles(
            discrepancies: [discrepancy], snapshots: [snapshot],
            volumes: f.volumeSnapshots(), progress: f.progress
        )

        // Copying an unverified replica would overwrite one corruption with another.
        guard case .failed = try #require(results.first).outcome else {
            Issue.record("a mis-hashing replica must not be treated as a repair source")
            return
        }
    }

    // MARK: - Repair strategy 2: PAR2

    @Test func repairFallsBackToPAR2WhenNoHealthyReplicaExists() async throws {
        let f = try Fixture()
        defer { f.cleanup() }

        // A real PAR2 set over real bytes, then damage the file in place.
        let good = Data((0..<8192).map { UInt8($0 % 251) })
        let expected = Fixture.sha256(good)
        let fileURL = try f.write(good, named: "photo.jpg", on: f.volumeA)

        let redundancy = RedundancyService()
        let par2URL = try redundancy.generatePAR2(for: fileURL, outputDirectory: f.albumDir(f.volumeA))

        var damaged = good
        damaged.replaceSubrange(100..<200, with: Data(repeating: 0xFF, count: 100))
        try damaged.write(to: fileURL)
        #expect(Fixture.sha256(try Data(contentsOf: fileURL)) != expected, "test setup failed to corrupt")

        let snapshot = ImageSnapshot(
            sha256: expected, filename: "photo.jpg",
            par2Filename: par2URL.lastPathComponent, b2FileId: nil,
            storageLocations: [f.location("vol-a", "photo.jpg")], albumPath: f.albumPath
        )
        let discrepancy = Discrepancy(
            sha256: expected, filename: "photo.jpg",
            kind: .hashMismatch(volumeID: "vol-a", expected: expected, actual: Fixture.sha256(damaged))
        )

        let results = await ReconciliationService().repairCorruptedFiles(
            discrepancies: [discrepancy], snapshots: [snapshot],
            volumes: f.volumeSnapshots(), progress: f.progress
        )

        let result = try #require(results.first)
        guard case .repairedViaPAR2 = result.outcome else {
            Issue.record("expected .repairedViaPAR2, got \(String(describing: result.outcome))")
            return
        }
        // Reed-Solomon recovery must reproduce the original bytes exactly.
        #expect(Fixture.sha256(try Data(contentsOf: fileURL)) == expected)
    }

    @Test func unrecoverableCorruptionIsReportedRatherThanSilentlyPassed() async throws {
        let f = try Fixture()
        defer { f.cleanup() }

        let expected = Fixture.sha256(Data("original".utf8))
        try f.write(Data("rotted".utf8), named: "photo.jpg", on: f.volumeA)

        // No second replica, no PAR2 set.
        let snapshot = ImageSnapshot(
            sha256: expected, filename: "photo.jpg", par2Filename: "", b2FileId: nil,
            storageLocations: [f.location("vol-a", "photo.jpg")], albumPath: f.albumPath
        )
        let discrepancy = Discrepancy(
            sha256: expected, filename: "photo.jpg",
            kind: .hashMismatch(volumeID: "vol-a", expected: expected, actual: "x")
        )

        let results = await ReconciliationService().repairCorruptedFiles(
            discrepancies: [discrepancy], snapshots: [snapshot],
            volumes: f.volumeSnapshots(), progress: f.progress
        )
        guard case .failed = try #require(results.first).outcome else {
            Issue.record("unrepairable corruption must be surfaced, not reported as success")
            return
        }
    }

    // MARK: - Safety

    @Test func repairRefusesARelativePathThatEscapesTheVolumeRoot() async throws {
        let f = try Fixture()
        defer { f.cleanup() }

        // A tampered catalog aiming the *write* side of a repair outside the volume.
        let outside = f.root.appendingPathComponent("outside.txt")
        try Data("do not touch".utf8).write(to: outside)

        let expected = Fixture.sha256(Data("anything".utf8))
        let snapshot = ImageSnapshot(
            sha256: expected, filename: "outside.txt", par2Filename: "", b2FileId: nil,
            storageLocations: [StorageLocation(volumeID: "vol-a", relativePath: "../outside.txt")],
            albumPath: f.albumPath
        )
        let discrepancy = Discrepancy(
            sha256: expected, filename: "outside.txt",
            kind: .hashMismatch(volumeID: "vol-a", expected: expected, actual: "x")
        )

        let results = await ReconciliationService().repairCorruptedFiles(
            discrepancies: [discrepancy], snapshots: [snapshot],
            volumes: f.volumeSnapshots(), progress: f.progress
        )
        guard case .failed(let reason) = try #require(results.first).outcome else {
            Issue.record("a traversing relativePath must be refused")
            return
        }
        #expect(reason.contains("outside the volume"))
        #expect(try Data(contentsOf: outside) == Data("do not touch".utf8), "file outside the volume was modified")
    }

    // MARK: - Bookkeeping

    @Test func repairIgnoresDiscrepancyKindsItCannotActOn() async throws {
        let f = try Fixture()
        defer { f.cleanup() }

        // Only hashMismatch is repairable; a dangling location has no bytes to fix.
        let discrepancy = Discrepancy(
            sha256: "aa", filename: "gone.jpg",
            kind: .danglingLocation(volumeID: "vol-a")
        )
        let results = await ReconciliationService().repairCorruptedFiles(
            discrepancies: [discrepancy], snapshots: [], volumes: f.volumeSnapshots(),
            progress: f.progress
        )
        #expect(results.isEmpty)
    }

    @Test func repairProgressReachesTheFullCountAcrossMixedOutcomes() async throws {
        let f = try Fixture()
        defer { f.cleanup() }

        // One repairable via replica, one hopeless — progress must still complete.
        let good = Data(repeating: 0x7E, count: 1024)
        let expectedGood = Fixture.sha256(good)
        try f.write(Data(repeating: 0x00, count: 1024), named: "a.jpg", on: f.volumeA)
        try f.write(good, named: "a.jpg", on: f.volumeB)
        try f.write(Data("rot".utf8), named: "b.jpg", on: f.volumeA)
        let expectedBad = Fixture.sha256(Data("original-b".utf8))

        let snapshots = [
            ImageSnapshot(sha256: expectedGood, filename: "a.jpg", par2Filename: "", b2FileId: nil,
                          storageLocations: [f.location("vol-a", "a.jpg"), f.location("vol-b", "a.jpg")],
                          albumPath: f.albumPath),
            ImageSnapshot(sha256: expectedBad, filename: "b.jpg", par2Filename: "", b2FileId: nil,
                          storageLocations: [f.location("vol-a", "b.jpg")], albumPath: f.albumPath)
        ]
        let discrepancies = [
            Discrepancy(sha256: expectedGood, filename: "a.jpg",
                        kind: .hashMismatch(volumeID: "vol-a", expected: expectedGood, actual: "x")),
            Discrepancy(sha256: expectedBad, filename: "b.jpg",
                        kind: .hashMismatch(volumeID: "vol-a", expected: expectedBad, actual: "y"))
        ]

        let results = await ReconciliationService().repairCorruptedFiles(
            discrepancies: discrepancies, snapshots: snapshots,
            volumes: f.volumeSnapshots(), progress: f.progress
        )

        #expect(results.count == 2)
        #expect(f.progress.processedItems == 2)
        #expect(f.progress.fraction == 1.0)
        #expect(results.contains { if case .copiedFromVolume = $0.outcome { return true }; return false })
        #expect(results.contains { if case .failed = $0.outcome { return true }; return false })
    }
}
