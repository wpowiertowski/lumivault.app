import Foundation

/// Identity of an external volume registered on some Mac — enough for another Mac to
/// recognize the same physical drive and re-register it under the same `volumeID`
/// (security-scoped bookmarks themselves are machine-specific and never sync).
nonisolated struct VolumeIdentity: Codable, Sendable, Hashable {
    var volumeID: String
    var label: String
}

/// settings.json — synced via the iCloud app container alongside catalog.json.
///
/// Every field is optional so older app versions keep decoding newer documents and a Mac
/// that never touched a setting doesn't clobber another Mac's value with a default.
/// Conflict resolution is last-writer-wins at document level, except `volumesByHost`
/// (each Mac only rewrites its own slot) and the encryption identity (first writer wins;
/// a device with a different existing key never overwrites the shared salt/keyId).
// nonisolated: this is a plain value type used from the SettingsSyncService actor;
// opting out of default MainActor isolation makes its Codable conformance and the
// apply/capture helpers callable there without actor hops.
nonisolated struct SyncedSettings: Codable, Sendable {
    var version: Int
    var lastUpdated: Date

    var importFormat: String?
    var importJpegQuality: Double?
    var importMaxDimension: Int?
    var importGeneratePAR2: Bool?
    var importDetectNearDuplicates: Bool?
    var importNearDuplicateThreshold: Int?
    var redundancyPercentage: Double?

    var b2Enabled: Bool?
    var b2BucketName: String?
    var b2SyncCredentialsViaICloud: Bool?

    var encryptionEnabled: Bool?
    /// Base64 PBKDF2 salt. Not secret — sharing it is what makes the same passphrase
    /// derive the same key on every Mac.
    var encryptionSalt: String?
    var encryptionKeyId: String?

    /// Volumes registered per device (keyed by `deviceIDDefaultsKey` UUID).
    var volumesByHost: [String: [VolumeIdentity]]?

    enum CodingKeys: String, CodingKey {
        case version
        case lastUpdated = "last_updated"
        case importFormat = "import_format"
        case importJpegQuality = "import_jpeg_quality"
        case importMaxDimension = "import_max_dimension"
        case importGeneratePAR2 = "import_generate_par2"
        case importDetectNearDuplicates = "import_detect_near_duplicates"
        case importNearDuplicateThreshold = "import_near_duplicate_threshold"
        case redundancyPercentage = "redundancy_percentage"
        case b2Enabled = "b2_enabled"
        case b2BucketName = "b2_bucket_name"
        case b2SyncCredentialsViaICloud = "b2_sync_credentials_via_icloud"
        case encryptionEnabled = "encryption_enabled"
        case encryptionSalt = "encryption_salt"
        case encryptionKeyId = "encryption_key_id"
        case volumesByHost = "volumes_by_host"
    }
}

nonisolated extension SyncedSettings {
    /// Preference keys mirrored between UserDefaults and the synced document.
    /// `catalogPath`, `iCloudSyncEnabled`, and `thumbnailCacheLimit` stay per-device.
    private static let boolKeys: [(key: String, path: WritableKeyPath<SyncedSettings, Bool?> & Sendable)] = [
        ("importGeneratePAR2", \.importGeneratePAR2),
        ("importDetectNearDuplicates", \.importDetectNearDuplicates),
        ("b2Enabled", \.b2Enabled),
        ("b2SyncCredentialsViaICloud", \.b2SyncCredentialsViaICloud),
        ("encryptionEnabled", \.encryptionEnabled)
    ]

    nonisolated static let knownRemoteVolumesDefaultsKey = "settingsSync.knownRemoteVolumes"
    nonisolated static let lastAppliedDefaultsKey = "settingsSync.lastApplied"
    nonisolated static let deviceIDDefaultsKey = "settingsSync.deviceID"

    /// Stable per-device UUID used as this Mac's slot key in `volumesByHost`.
    nonisolated static func deviceID(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: deviceIDDefaultsKey) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: deviceIDDefaultsKey)
        return fresh
    }

    /// Snapshot local preferences into a document, carrying forward remote state this
    /// device must not fight over (other hosts' volume slots, a divergent encryption
    /// identity). Fields the user never set locally stay nil unless remote had them.
    static func capture(
        defaults: UserDefaults = .standard,
        localVolumes: [VolumeIdentity],
        deviceID: String,
        remote: SyncedSettings?
    ) -> SyncedSettings {
        var doc = SyncedSettings(version: 1, lastUpdated: remote?.lastUpdated ?? .now)

        for entry in boolKeys {
            if defaults.object(forKey: entry.key) != nil {
                doc[keyPath: entry.path] = defaults.bool(forKey: entry.key)
            } else {
                // Carry remote forward for keys never touched locally so a push doesn't drop them.
                doc[keyPath: entry.path] = remote?[keyPath: entry.path]
            }
        }

        doc.importFormat = defaults.string(forKey: "importFormat") ?? remote?.importFormat
        doc.importJpegQuality = defaults.object(forKey: "importJpegQuality") != nil
            ? defaults.double(forKey: "importJpegQuality") : remote?.importJpegQuality
        doc.importMaxDimension = defaults.object(forKey: "importMaxDimension") != nil
            ? defaults.integer(forKey: "importMaxDimension") : remote?.importMaxDimension
        doc.importNearDuplicateThreshold = defaults.object(forKey: "importNearDuplicateThreshold") != nil
            ? defaults.integer(forKey: "importNearDuplicateThreshold") : remote?.importNearDuplicateThreshold
        doc.redundancyPercentage = defaults.object(forKey: "redundancyPercentage") != nil
            ? defaults.double(forKey: "redundancyPercentage") : remote?.redundancyPercentage
        doc.b2BucketName = defaults.string(forKey: "b2BucketName") ?? remote?.b2BucketName

        // Encryption identity: contribute ours only if the document has none or already
        // carries the same keyId. A device whose key diverges keeps the remote identity
        // in the doc (first writer wins) instead of ping-ponging the shared salt.
        let localKeyId = defaults.string(forKey: EncryptionService.keyIdDefaultsKey)
        let localSalt = defaults.data(forKey: EncryptionService.saltDefaultsKey)
        if let localKeyId, let localSalt,
           remote?.encryptionKeyId == nil || remote?.encryptionKeyId == localKeyId {
            doc.encryptionKeyId = localKeyId
            doc.encryptionSalt = localSalt.base64EncodedString()
        } else {
            doc.encryptionKeyId = remote?.encryptionKeyId
            doc.encryptionSalt = remote?.encryptionSalt
        }

        var hosts = remote?.volumesByHost ?? [:]
        // Deterministic order: [VolumeIdentity] compares order-sensitively in
        // contentEquals, and callers fetch volumes with no guaranteed order.
        // Unordered input made repeated captures compare "changed", so every
        // sync pass rewrote settings.json — which re-triggered the metadata
        // query and the next sync pass, forever, on a single Mac.
        hosts[deviceID] = localVolumes.sorted { $0.volumeID < $1.volumeID }
        doc.volumesByHost = hosts

        return doc
    }

    /// Write this document's values into local defaults. Called only when the remote
    /// document is newer than what this device last applied.
    func apply(defaults: UserDefaults = .standard, deviceID: String) {
        for entry in Self.boolKeys {
            if let value = self[keyPath: entry.path] { defaults.set(value, forKey: entry.key) }
        }
        if let value = importFormat { defaults.set(value, forKey: "importFormat") }
        if let value = importJpegQuality { defaults.set(value, forKey: "importJpegQuality") }
        if let value = importMaxDimension { defaults.set(value, forKey: "importMaxDimension") }
        if let value = importNearDuplicateThreshold { defaults.set(value, forKey: "importNearDuplicateThreshold") }
        if let value = redundancyPercentage { defaults.set(value, forKey: "redundancyPercentage") }
        if let value = b2BucketName { defaults.set(value, forKey: "b2BucketName") }

        // Adopt the shared encryption salt/keyId only when this device has no key yet —
        // then the user's original passphrase unlocks here too. Never overwrite an
        // existing local key: files encrypted with it would become undecryptable.
        if let saltB64 = encryptionSalt, let salt = Data(base64Encoded: saltB64), let keyId = encryptionKeyId,
           defaults.string(forKey: EncryptionService.keyIdDefaultsKey) == nil {
            defaults.set(salt, forKey: EncryptionService.saltDefaultsKey)
            defaults.set(keyId, forKey: EncryptionService.keyIdDefaultsKey)
        }

        // Stash other Macs' volume identities for the Volumes settings UI.
        let remoteVolumes = (volumesByHost ?? [:])
            .filter { $0.key != deviceID }
            .values.flatMap(\.self)
        var seen = Set<String>()
        let unique = remoteVolumes.filter { seen.insert($0.volumeID).inserted }
            .sorted { $0.volumeID < $1.volumeID }
        if let data = try? JSONEncoder().encode(unique) {
            defaults.set(data, forKey: Self.knownRemoteVolumesDefaultsKey)
        }
    }

    /// Volumes registered on other Macs, as last applied from the synced document.
    static func knownRemoteVolumes(defaults: UserDefaults = .standard) -> [VolumeIdentity] {
        guard let data = defaults.data(forKey: knownRemoteVolumesDefaultsKey),
              let identities = try? JSONDecoder().decode([VolumeIdentity].self, from: data) else {
            return []
        }
        return identities
    }

    /// Field-wise equality ignoring `lastUpdated`, to decide whether a push is needed.
    func contentEquals(_ other: SyncedSettings?) -> Bool {
        guard let other else { return false }
        return importFormat == other.importFormat
            && importJpegQuality == other.importJpegQuality
            && importMaxDimension == other.importMaxDimension
            && importGeneratePAR2 == other.importGeneratePAR2
            && importDetectNearDuplicates == other.importDetectNearDuplicates
            && importNearDuplicateThreshold == other.importNearDuplicateThreshold
            && redundancyPercentage == other.redundancyPercentage
            && b2Enabled == other.b2Enabled
            && b2BucketName == other.b2BucketName
            && b2SyncCredentialsViaICloud == other.b2SyncCredentialsViaICloud
            && encryptionEnabled == other.encryptionEnabled
            && encryptionSalt == other.encryptionSalt
            && encryptionKeyId == other.encryptionKeyId
            && (volumesByHost ?? [:]) == (other.volumesByHost ?? [:])
    }
}
