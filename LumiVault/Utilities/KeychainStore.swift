import Foundation
import Security

/// Thin wrapper over the Keychain (generic-password items) for storing small secrets.
///
/// Used for Backblaze B2 credentials, which are long-lived bearer secrets that grant
/// read/write/delete on the bucket. The Keychain keeps them out of the app's
/// world-readable (to the user's own uid) preferences plist and gates access via the
/// system. Items are device-scoped by default; passing `synchronizable: true` stores
/// the item in iCloud Keychain so the user's other Macs can read it (opt-in).
enum KeychainStore {
    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    private static let service = "app.lumivault.credentials"

    /// Store (or replace) `data` under `account`. Idempotent within one `synchronizable`
    /// mode; the query only matches items of the same mode, so callers switching modes
    /// must `delete` first (see `B2Credentials.setSyncViaICloudKeychain`).
    static func set(_ data: Data, account: String, synchronizable: Bool = false) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // ThisDeviceOnly accessibility is incompatible with iCloud Keychain sync.
            kSecAttrAccessible as String: synchronizable
                ? kSecAttrAccessibleAfterFirstUnlock
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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

    /// Fetch the data stored under `account`, or nil if absent. Matches both device-only
    /// and iCloud-synced items, so a credential saved on another Mac is found here.
    static func get(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Remove the item stored under `account` — both device-only and synced variants.
    /// No-op if absent.
    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(query as CFDictionary)
    }
}
