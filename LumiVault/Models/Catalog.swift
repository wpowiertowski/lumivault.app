import Foundation
import CryptoKit

// MARK: - catalog.json Codable Structs

struct Catalog: Codable, Sendable {
    var version: Int
    var lastUpdated: Date
    var years: [String: CatalogYear]

    enum CodingKeys: String, CodingKey {
        case version
        case lastUpdated = "last_updated"
        case years
    }
}

struct CatalogYear: Codable, Sendable {
    var months: [String: CatalogMonth]
}

struct CatalogMonth: Codable, Sendable {
    var days: [String: CatalogDay]
}

struct CatalogDay: Codable, Sendable {
    var albums: [String: CatalogAlbum]
}

struct CatalogAlbum: Codable, Sendable {
    var addedAt: Date
    var images: [CatalogImage]

    enum CodingKeys: String, CodingKey {
        case addedAt = "added_at"
        case images
    }
}

struct CatalogImage: Codable, Sendable {
    var filename: String
    var sha256: String
    var sizeBytes: Int64
    var par2Filename: String
    var b2FileId: String?
    // Encryption — optional, nil for unencrypted (backwards-compatible)
    var encryptionAlgorithm: String?
    var encryptionKeyId: String?
    var encryptionNonce: String?       // base64-encoded 12-byte nonce
    var encryptedSizeBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case filename
        case sha256
        case sizeBytes = "size_bytes"
        case par2Filename = "par2_filename"
        case b2FileId = "b2_file_id"
        case encryptionAlgorithm = "encryption_algorithm"
        case encryptionKeyId = "encryption_key_id"
        case encryptionNonce = "encryption_nonce"
        case encryptedSizeBytes = "encrypted_size_bytes"
    }
}

// MARK: - Encoder/Decoder Helpers

extension Catalog {
    static func load(from url: URL) throws -> Catalog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        return try decoder.decode(Catalog.self, from: data)
    }

    func save(to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)

        // Write SHA-256 checksum sidecar
        let checksum = Catalog.sha256Hex(of: data)
        let checksumURL = Catalog.checksumURL(for: url)
        try checksum.write(to: checksumURL, atomically: true, encoding: .utf8)

        // Generate PAR2 error correction data
        let redundancy = RedundancyService()
        _ = try redundancy.generatePAR2(for: url, outputDirectory: dir)
    }

    // MARK: - Integrity

    enum IntegrityStatus: Sendable, Equatable {
        case valid
        /// Corruption detected and automatically repaired via PAR2.
        case repaired
        /// Corruption detected but repair failed or PAR2 unavailable.
        case corrupt(expected: String, actual: String)
        /// No checksum sidecar found (first run or legacy catalog).
        case checksumMissing
    }

    /// Verify the catalog file against its `.sha256` sidecar.
    /// If corruption is detected and a `.par2` sidecar exists, attempts automatic repair.
    static func verifyIntegrity(at url: URL) -> IntegrityStatus {
        let checksumURL = checksumURL(for: url)
        guard let storedChecksum = try? String(contentsOf: checksumURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .checksumMissing
        }
        guard let catalogData = try? Data(contentsOf: url) else {
            return .corrupt(expected: storedChecksum, actual: "unreadable")
        }
        let actual = sha256Hex(of: catalogData)
        if actual == storedChecksum {
            return .valid
        }

        // Corruption detected — attempt PAR2 repair
        let par2 = par2URL(for: url)
        guard FileManager.default.fileExists(atPath: par2.path) else {
            return .corrupt(expected: storedChecksum, actual: actual)
        }

        let redundancy = RedundancyService()
        guard let repairedData = try? redundancy.repair(par2URL: par2, corruptedFileURL: url) else {
            return .corrupt(expected: storedChecksum, actual: actual)
        }

        // Verify repaired data matches expected checksum
        let repairedChecksum = sha256Hex(of: repairedData)
        guard repairedChecksum == storedChecksum else {
            return .corrupt(expected: storedChecksum, actual: actual)
        }

        // Write repaired catalog back to disk
        guard let _ = try? repairedData.write(to: url, options: .atomic) else {
            return .corrupt(expected: storedChecksum, actual: actual)
        }

        return .repaired
    }

    static func checksumURL(for catalogURL: URL) -> URL {
        catalogURL.appendingPathExtension("sha256")
    }

    static func par2URL(for catalogURL: URL) -> URL {
        catalogURL.appendingPathExtension("par2")
    }

    nonisolated static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
