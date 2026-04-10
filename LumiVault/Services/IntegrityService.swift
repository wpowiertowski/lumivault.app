import Foundation
import CryptoKit
import SwiftData

actor IntegrityService {
    private let hasher = HasherService()

    enum VerificationMethod: Sendable, Equatable {
        /// SHA-256 comparison against stored plaintext hash.
        case sha256
        /// AES-GCM authentication tag verified the ciphertext and AAD.
        case gcmTag
        /// Encrypted file could not be verified (no encryption key available).
        case skipped
    }

    struct VerificationResult: Sendable {
        let sha256: String
        let filename: String
        let passed: Bool
        let expectedHash: String
        let actualHash: String?
        let method: VerificationMethod
    }

    func verify(
        images: [ImageRecord],
        sourceResolver: @Sendable (ImageRecord) -> URL?,
        encryptionKey: SymmetricKey? = nil,
        batchSize: Int = 50
    ) async -> [VerificationResult] {
        var results: [VerificationResult] = []
        let batch = Array(images.prefix(batchSize))

        for image in batch {
            guard let url = sourceResolver(image) else {
                results.append(VerificationResult(
                    sha256: image.sha256, filename: image.filename, passed: false,
                    expectedHash: image.sha256, actualHash: nil, method: .sha256
                ))
                continue
            }

            if image.isEncrypted {
                results.append(verifyEncrypted(image: image, at: url, key: encryptionKey))
            } else {
                results.append(await verifyPlaintext(image: image, at: url))
            }
        }

        return results
    }

    // MARK: - Private

    private func verifyPlaintext(image: ImageRecord, at url: URL) async -> VerificationResult {
        do {
            let hash = try await hasher.sha256(of: url)
            let passed = hash == image.sha256
            return VerificationResult(
                sha256: image.sha256, filename: image.filename, passed: passed,
                expectedHash: image.sha256, actualHash: hash, method: .sha256
            )
        } catch {
            return VerificationResult(
                sha256: image.sha256, filename: image.filename, passed: false,
                expectedHash: image.sha256, actualHash: nil, method: .sha256
            )
        }
    }

    private func verifyEncrypted(
        image: ImageRecord, at url: URL, key: SymmetricKey?
    ) -> VerificationResult {
        guard let key, let nonce = image.encryptionNonce else {
            return VerificationResult(
                sha256: image.sha256, filename: image.filename, passed: false,
                expectedHash: image.sha256, actualHash: nil, method: .skipped
            )
        }

        do {
            let passed = try EncryptionService.verifyGCMIntegrity(
                at: url, nonce: nonce, sha256: image.sha256, key: key
            )
            return VerificationResult(
                sha256: image.sha256, filename: image.filename, passed: passed,
                expectedHash: image.sha256, actualHash: nil, method: .gcmTag
            )
        } catch {
            return VerificationResult(
                sha256: image.sha256, filename: image.filename, passed: false,
                expectedHash: image.sha256, actualHash: nil, method: .gcmTag
            )
        }
    }

    func oldestUnchecked(in context: ModelContext, limit: Int = 50) throws -> [ImageRecord] {
        let descriptor = FetchDescriptor<ImageRecord>(
            sortBy: [SortDescriptor(\ImageRecord.lastVerifiedAt, order: .forward)]
        )
        let all = try context.fetch(descriptor)
        return Array(all.prefix(limit))
    }
}
