import Testing
import Foundation
@testable import LumiVault

// MARK: - SettingsSyncService Tests
//
// Exercises the settings.json pull-apply-push cycle against a temp directory and an
// isolated UserDefaults suite, using the test-only initializer that bypasses
// NSFileCoordinator and the iCloud ubiquity container.

@Suite
@MainActor
struct SettingsSyncServiceTests {

    // MARK: - Helpers

    func makeDefaults() -> (suiteName: String, defaults: UserDefaults) {
        let name = "lumivault-settings-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (name, defaults)
    }

    func makeSyncURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-settings-sync-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
    }

    func writeRemote(_ settings: SyncedSettings, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(settings).write(to: url, options: .atomic)
    }

    func readRemote(_ url: URL) throws -> SyncedSettings {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SyncedSettings.self, from: try Data(contentsOf: url))
    }

    // MARK: - Push

    @Test func pushWritesLocalPreferencesToDocument() async throws {
        let syncURL = makeSyncURL()
        defer { try? FileManager.default.removeItem(at: syncURL.deletingLastPathComponent()) }
        let (suiteName, defaults) = makeDefaults()

        defaults.set(0.7, forKey: "importJpegQuality")
        defaults.set(true, forKey: "importGeneratePAR2")
        defaults.set("my-bucket", forKey: "b2BucketName")

        let service = SettingsSyncService(syncURL: syncURL, defaultsSuiteName: suiteName)
        try await service.sync(localVolumes: [])

        let doc = try readRemote(syncURL)
        #expect(doc.importJpegQuality == 0.7)
        #expect(doc.importGeneratePAR2 == true)
        #expect(doc.b2BucketName == "my-bucket")
        // Keys never touched locally stay absent rather than pushing defaults.
        #expect(doc.importDetectNearDuplicates == nil)
    }

    @Test func captureNormalizesVolumeOrderSoRepeatedSyncsSettle() async throws {
        // [VolumeIdentity] compares order-sensitively in contentEquals, and
        // volume fetch order is unspecified. Unsorted input made every sync
        // pass see "changed" content and rewrite settings.json — re-triggering
        // the metadata query in an endless single-Mac loop.
        let (_, defaults) = makeDefaults()
        let v1 = VolumeIdentity(volumeID: "vol-a", label: "Archive A")
        let v2 = VolumeIdentity(volumeID: "vol-b", label: "Archive B")

        let first = SyncedSettings.capture(
            defaults: defaults, localVolumes: [v1, v2], deviceID: "dev-1", remote: nil
        )
        let reordered = SyncedSettings.capture(
            defaults: defaults, localVolumes: [v2, v1], deviceID: "dev-1", remote: first
        )

        #expect(reordered.contentEquals(first))
    }

    @Test func repeatedSyncWithReorderedVolumesDoesNotRewriteDocument() async throws {
        let syncURL = makeSyncURL()
        defer { try? FileManager.default.removeItem(at: syncURL.deletingLastPathComponent()) }
        let (suiteName, _) = makeDefaults()

        let v1 = VolumeIdentity(volumeID: "vol-a", label: "Archive A")
        let v2 = VolumeIdentity(volumeID: "vol-b", label: "Archive B")

        let service = SettingsSyncService(syncURL: syncURL, defaultsSuiteName: suiteName)
        try await service.sync(localVolumes: [v1, v2])
        let dateAfterFirst = try FileManager.default
            .attributesOfItem(atPath: syncURL.path)[.modificationDate] as? Date

        // Same volumes, opposite order — must be a no-op, not a rewrite.
        try await service.sync(localVolumes: [v2, v1])
        let dateAfterSecond = try FileManager.default
            .attributesOfItem(atPath: syncURL.path)[.modificationDate] as? Date

        #expect(dateAfterFirst == dateAfterSecond)
    }

    // MARK: - Pull / apply

    @Test func pullAppliesNewerRemoteToDefaults() async throws {
        let syncURL = makeSyncURL()
        defer { try? FileManager.default.removeItem(at: syncURL.deletingLastPathComponent()) }
        let (suiteName, defaults) = makeDefaults()

        var remote = SyncedSettings(version: 1, lastUpdated: .now)
        remote.importJpegQuality = 0.5
        remote.b2Enabled = true
        try writeRemote(remote, to: syncURL)

        let service = SettingsSyncService(syncURL: syncURL, defaultsSuiteName: suiteName)
        try await service.sync(localVolumes: [])

        #expect(defaults.double(forKey: "importJpegQuality") == 0.5)
        #expect(defaults.bool(forKey: "b2Enabled") == true)
    }

    @Test func secondSyncIsANoOp() async throws {
        let syncURL = makeSyncURL()
        defer { try? FileManager.default.removeItem(at: syncURL.deletingLastPathComponent()) }
        let (suiteName, defaults) = makeDefaults()
        defaults.set(0.9, forKey: "importJpegQuality")

        let service = SettingsSyncService(syncURL: syncURL, defaultsSuiteName: suiteName)
        try await service.sync(localVolumes: [])
        let firstWrite = try Data(contentsOf: syncURL)

        try await service.sync(localVolumes: [])
        let secondWrite = try Data(contentsOf: syncURL)

        // No local change between syncs → the document must not be rewritten
        // (no push ping-pong between Macs).
        #expect(firstWrite == secondWrite)
    }

    // MARK: - Encryption identity

    @Test func adoptsRemoteEncryptionIdentityWhenNoLocalKey() async throws {
        let syncURL = makeSyncURL()
        defer { try? FileManager.default.removeItem(at: syncURL.deletingLastPathComponent()) }
        let (suiteName, defaults) = makeDefaults()

        let salt = Data((0..<32).map { UInt8($0) })
        var remote = SyncedSettings(version: 1, lastUpdated: .now)
        remote.encryptionSalt = salt.base64EncodedString()
        remote.encryptionKeyId = "aabbccdd00112233"
        try writeRemote(remote, to: syncURL)

        let service = SettingsSyncService(syncURL: syncURL, defaultsSuiteName: suiteName)
        try await service.sync(localVolumes: [])

        #expect(defaults.data(forKey: EncryptionService.saltDefaultsKey) == salt)
        #expect(defaults.string(forKey: EncryptionService.keyIdDefaultsKey) == "aabbccdd00112233")
    }

    @Test func neverOverwritesExistingLocalKeyAndKeepsRemoteIdentityInDocument() async throws {
        let syncURL = makeSyncURL()
        defer { try? FileManager.default.removeItem(at: syncURL.deletingLastPathComponent()) }
        let (suiteName, defaults) = makeDefaults()

        // This device already has its own (divergent) key.
        let localSalt = Data(repeating: 0x22, count: 32)
        defaults.set(localSalt, forKey: EncryptionService.saltDefaultsKey)
        defaults.set("localkey00000000", forKey: EncryptionService.keyIdDefaultsKey)

        var remote = SyncedSettings(version: 1, lastUpdated: .now)
        remote.encryptionSalt = Data(repeating: 0x11, count: 32).base64EncodedString()
        remote.encryptionKeyId = "remotekey0000000"
        try writeRemote(remote, to: syncURL)

        let service = SettingsSyncService(syncURL: syncURL, defaultsSuiteName: suiteName)
        try await service.sync(localVolumes: [])

        // Local key untouched…
        #expect(defaults.data(forKey: EncryptionService.saltDefaultsKey) == localSalt)
        #expect(defaults.string(forKey: EncryptionService.keyIdDefaultsKey) == "localkey00000000")
        // …and the shared document still carries the first writer's identity.
        let doc = try readRemote(syncURL)
        #expect(doc.encryptionKeyId == "remotekey0000000")
    }

    // MARK: - Volume identities

    @Test func volumeSlotsMergePerHost() async throws {
        let syncURL = makeSyncURL()
        defer { try? FileManager.default.removeItem(at: syncURL.deletingLastPathComponent()) }
        let (suiteName, defaults) = makeDefaults()
        defaults.set("device-me", forKey: SyncedSettings.deviceIDDefaultsKey)

        let otherVolume = VolumeIdentity(volumeID: "vol-other", label: "Backup A")
        var remote = SyncedSettings(version: 1, lastUpdated: .now)
        remote.volumesByHost = ["device-other": [otherVolume]]
        try writeRemote(remote, to: syncURL)

        let myVolume = VolumeIdentity(volumeID: "vol-mine", label: "Backup B")
        let service = SettingsSyncService(syncURL: syncURL, defaultsSuiteName: suiteName)
        try await service.sync(localVolumes: [myVolume])

        // Document holds both hosts' slots.
        let doc = try readRemote(syncURL)
        #expect(doc.volumesByHost?["device-other"] == [otherVolume])
        #expect(doc.volumesByHost?["device-me"] == [myVolume])

        // The other Mac's volume is exposed locally for the "Locate…" UI.
        #expect(SyncedSettings.knownRemoteVolumes(defaults: defaults) == [otherVolume])
    }
}
