import Foundation

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
    }
}
