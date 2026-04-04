import Foundation
import SwiftData

actor IntegrityService {
    private let hasher = HasherService()

    struct VerificationResult: Sendable {
        let sha256: String
        let filename: String
        let passed: Bool
        let expectedHash: String
        let actualHash: String?
    }

    func verify(
        images: [ImageRecord],
        sourceResolver: @Sendable (ImageRecord) -> URL?,
        batchSize: Int = 50
    ) async -> [VerificationResult] {
        var results: [VerificationResult] = []
        let batch = Array(images.prefix(batchSize))

        for image in batch {
            guard let url = sourceResolver(image) else {
                results.append(VerificationResult(
                    sha256: image.sha256, filename: image.filename, passed: false,
                    expectedHash: image.sha256, actualHash: nil
                ))
                continue
            }

            do {
                let hash = try await hasher.sha256(of: url)
                let passed = hash == image.sha256
                results.append(VerificationResult(
                    sha256: image.sha256, filename: image.filename, passed: passed,
                    expectedHash: image.sha256, actualHash: hash
                ))
            } catch {
                results.append(VerificationResult(
                    sha256: image.sha256, filename: image.filename, passed: false,
                    expectedHash: image.sha256, actualHash: nil
                ))
            }
        }

        return results
    }

    func oldestUnchecked(in context: ModelContext, limit: Int = 50) throws -> [ImageRecord] {
        let descriptor = FetchDescriptor<ImageRecord>(
            sortBy: [SortDescriptor(\ImageRecord.lastVerifiedAt, order: .forward)]
        )
        let all = try context.fetch(descriptor)
        return Array(all.prefix(limit))
    }
}
