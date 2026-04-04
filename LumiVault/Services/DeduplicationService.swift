import Foundation
import SwiftData

enum DuplicateResult {
    case unique
    case exactMatch(ImageRecord)
    case nearMatch(ImageRecord, hammingDistance: Int)
}

actor DeduplicationService {
    private let hasher = HasherService()
    private static let nearDuplicateThreshold = 5

    func check(fileURL: URL, in context: ModelContext) async throws -> (DuplicateResult, String, Int64) {
        let (hash, size) = try await hasher.sha256AndSize(of: fileURL)

        // Exact match
        let descriptor = FetchDescriptor<ImageRecord>(
            predicate: #Predicate { $0.sha256 == hash }
        )
        if let existing = try context.fetch(descriptor).first {
            return (.exactMatch(existing), hash, size)
        }

        // Near-duplicate via perceptual hash
        let pHash = try PerceptualHash.compute(for: fileURL)
        let allDescriptor = FetchDescriptor<ImageRecord>(
            predicate: #Predicate { $0.perceptualHash != nil }
        )
        let candidates = try context.fetch(allDescriptor)

        for candidate in candidates {
            guard let candidateHash = candidate.perceptualHash else { continue }
            let distance = PerceptualHash.hammingDistance(pHash, candidateHash)
            if distance < Self.nearDuplicateThreshold {
                return (.nearMatch(candidate, hammingDistance: distance), hash, size)
            }
        }

        return (.unique, hash, size)
    }
}
