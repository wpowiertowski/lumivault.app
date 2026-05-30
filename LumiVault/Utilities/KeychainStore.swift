import Foundation
import Security

/// Thin wrapper over the Keychain (generic-password items) for storing small secrets.
///
/// Used for Backblaze B2 credentials, which are long-lived bearer secrets that grant
/// read/write/delete on the bucket. The Keychain keeps them out of the app's
/// world-readable (to the user's own uid) preferences plist and gates access via the
/// system. Items are scoped to this device and never synced to iCloud.
enum KeychainStore {
    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    private static let service = "app.lumivault.credentials"

    /// Store (or replace) `data` under `account`. Idempotent.
    static func set(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            let addQuery = query.merging(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
            return
        }

        throw KeychainError.unexpectedStatus(updateStatus)
    }

    /// Fetch the data stored under `account`, or nil if absent.
    static func get(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Remove the item stored under `account`. No-op if absent.
    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
