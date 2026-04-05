import Foundation
import CryptoKit
import CommonCrypto
import SwiftUI

// MARK: - Environment Key

private struct EncryptionServiceKey: EnvironmentKey {
    static let defaultValue: EncryptionService = EncryptionService()
}

extension EnvironmentValues {
    var encryptionService: EncryptionService {
        get { self[EncryptionServiceKey.self] }
        set { self[EncryptionServiceKey.self] = newValue }
    }
}

actor EncryptionService {
    private(set) var cachedKey: SymmetricKey?
    private(set) var cachedKeyId: String?

    private static let pbkdf2Iterations: UInt32 = 600_000
    private static let saltKey = "encryption.salt"
    private static let keyIdKey = "encryption.keyId"
    private static let infoString = "LumiVault-file-encryption-v1"

    var isKeyAvailable: Bool { cachedKey != nil }

    // MARK: - Key Derivation

    nonisolated func deriveKey(passphrase: String, salt: Data) -> (key: SymmetricKey, keyId: String) {
        // PBKDF2 with SHA-256 for password stretching
        var derivedBytes = [UInt8](repeating: 0, count: 32)
        let passphraseData = Array(passphrase.utf8)

        salt.withUnsafeBytes { saltBuffer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passphraseData, passphraseData.count,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                Self.pbkdf2Iterations,
                &derivedBytes, 32
            )
        }

        let key = SymmetricKey(data: derivedBytes)

        // Key ID = first 16 hex chars of SHA-256(derived key)
        let keyHash = SHA256.hash(data: derivedBytes)
        let keyId = keyHash.prefix(8).map { String(format: "%02x", $0) }.joined()

        return (key, keyId)
    }

    func setKey(_ key: SymmetricKey, keyId: String) {
        cachedKey = key
        cachedKeyId = keyId
    }

    func clearKey() {
        cachedKey = nil
        cachedKeyId = nil
    }

    // MARK: - Salt Management

    nonisolated static func getOrCreateSalt() -> Data {
        if let existing = UserDefaults.standard.data(forKey: saltKey) {
            return existing
        }
        var salt = Data(count: 32)
        salt.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        UserDefaults.standard.set(salt, forKey: saltKey)
        return salt
    }

    nonisolated static func storedKeyId() -> String? {
        UserDefaults.standard.string(forKey: keyIdKey)
    }

    nonisolated static func storeKeyId(_ keyId: String) {
        UserDefaults.standard.set(keyId, forKey: keyIdKey)
    }

    // MARK: - Encrypt / Decrypt Data

    func encrypt(data: Data, associatedData: Data? = nil) throws -> (ciphertext: Data, nonce: AES.GCM.Nonce) {
        guard let key = cachedKey else { throw EncryptionError.noKey }

        let nonce = AES.GCM.Nonce()
        let sealedBox: AES.GCM.SealedBox
        if let ad = associatedData {
            sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce, authenticating: ad)
        } else {
            sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)
        }

        // Combined = nonce (12) + ciphertext + tag (16)
        // We store nonce separately, so return ciphertext + tag
        guard let combined = sealedBox.combined else {
            throw EncryptionError.sealFailed
        }
        // Strip the 12-byte nonce prefix from combined representation
        let ciphertextAndTag = combined.dropFirst(12)
        return (Data(ciphertextAndTag), nonce)
    }

    func decrypt(ciphertext: Data, nonce: Data, associatedData: Data? = nil) throws -> Data {
        guard let key = cachedKey else { throw EncryptionError.noKey }

        let gcmNonce = try AES.GCM.Nonce(data: nonce)
        // Reconstruct combined: nonce + ciphertext + tag
        let combined = nonce + ciphertext
        let sealedBox = try AES.GCM.SealedBox(combined: combined)

        if let ad = associatedData {
            return try AES.GCM.open(sealedBox, using: key, authenticating: ad)
        } else {
            return try AES.GCM.open(sealedBox, using: key)
        }
    }

    // MARK: - File-Level Encrypt / Decrypt

    func encryptFile(at source: URL, to destination: URL, sha256: String) throws -> (nonce: Data, encryptedSize: Int64) {
        let rawData = try Data(contentsOf: source)
        let associatedData = Data(sha256.utf8)

        let (ciphertext, nonce) = try encrypt(data: rawData, associatedData: associatedData)
        try ciphertext.write(to: destination, options: .atomic)

        return (Data(nonce), Int64(ciphertext.count))
    }

    func decryptFile(at source: URL, to destination: URL, nonce: Data, sha256: String) throws {
        let ciphertext = try Data(contentsOf: source)
        let associatedData = Data(sha256.utf8)

        let plaintext = try decrypt(ciphertext: ciphertext, nonce: nonce, associatedData: associatedData)
        try plaintext.write(to: destination, options: .atomic)
    }

    /// Decrypt file data in memory (for display without temp file).
    func decryptData(_ ciphertext: Data, nonce: Data, sha256: String) throws -> Data {
        let associatedData = Data(sha256.utf8)
        return try decrypt(ciphertext: ciphertext, nonce: nonce, associatedData: associatedData)
    }

    // MARK: - Errors

    enum EncryptionError: Error, LocalizedError {
        case noKey
        case sealFailed
        case decryptionFailed

        var errorDescription: String? {
            switch self {
            case .noKey:
                "No encryption key available. Set up a passphrase in Settings > Encryption."
            case .sealFailed:
                "Encryption failed. The file could not be sealed."
            case .decryptionFailed:
                "Decryption failed. The passphrase may be incorrect or the file may be corrupted."
            }
        }
    }
}
