import Foundation

struct B2Credentials: Codable, Sendable {
    var applicationKeyId: String
    var applicationKey: String
    var bucketId: String
    var bucketName: String

    /// Legacy UserDefaults key — retained only for the one-time migration into the Keychain.
    static let defaultsKey = "b2.credentials"

    /// Keychain account under which the credentials blob is stored.
    private static let keychainAccount = "b2.credentials"

    // MARK: - Persistence (Keychain-backed)

    /// Load credentials from the Keychain, migrating any legacy UserDefaults copy first.
    static func load() -> B2Credentials? {
        migrateFromUserDefaultsIfNeeded()
        guard let data = KeychainStore.get(account: keychainAccount),
              let credentials = try? JSONDecoder().decode(B2Credentials.self, from: data) else {
            return nil
        }
        return credentials
    }

    /// True if credentials are stored, without decoding them.
    static var isConfigured: Bool {
        migrateFromUserDefaultsIfNeeded()
        return KeychainStore.get(account: keychainAccount) != nil
    }

    /// Persist these credentials to the Keychain.
    func save() throws {
        let data = try JSONEncoder().encode(self)
        try KeychainStore.set(data, account: Self.keychainAccount)
    }

    /// Remove stored credentials from both the Keychain and any legacy UserDefaults copy.
    static func delete() {
        KeychainStore.delete(account: keychainAccount)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// One-time migration: if a plaintext blob exists in UserDefaults but not yet in the
    /// Keychain, move it into the Keychain and scrub the UserDefaults copy. Idempotent.
    private static func migrateFromUserDefaultsIfNeeded() {
        guard let legacy = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        if KeychainStore.get(account: keychainAccount) == nil {
            // Only scrub the legacy plaintext copy once it is safely in the Keychain.
            // If the write fails (locked keychain, ACL error), keep UserDefaults intact
            // so the credentials are not lost from both stores — retry on next launch.
            guard (try? KeychainStore.set(legacy, account: keychainAccount)) != nil else { return }
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

struct B2Authorization: Codable, Sendable {
    var authorizationToken: String
    var apiURL: String
    var downloadURL: String
    var recommendedPartSize: Int

    enum CodingKeys: String, CodingKey {
        case authorizationToken
        case apiURL = "apiUrl"
        case downloadURL = "downloadUrl"
        case recommendedPartSize
    }
}

struct B2UploadURL: Codable, Sendable {
    var uploadUrl: String
    var authorizationToken: String
}

struct B2FileResponse: Codable, Sendable {
    var fileId: String
    var fileName: String
    var contentSha1: String
}

struct B2FileListing: Sendable {
    let fileId: String
    let fileName: String
    let contentLength: Int64
}
