import Foundation
import CryptoKit

// MARK: - catalog.json Codable Structs

nonisolated struct Catalog: Codable, Sendable, Equatable {
    var version: Int
    var lastUpdated: Date
    var years: [String: CatalogYear]

    enum CodingKeys: String, CodingKey {
        case version
        case lastUpdated = "last_updated"
        case years
    }
}

nonisolated struct CatalogYear: Codable, Sendable, Equatable {
    var months: [String: CatalogMonth]
}

nonisolated struct CatalogMonth: Codable, Sendable, Equatable {
    var days: [String: CatalogDay]
}

nonisolated struct CatalogDay: Codable, Sendable, Equatable {
    var albums: [String: CatalogAlbum]
}

nonisolated struct CatalogAlbum: Codable, Sendable, Equatable {
    var addedAt: Date
    var images: [CatalogImage]

    enum CodingKeys: String, CodingKey {
        case addedAt = "added_at"
        case images
    }
}

nonisolated struct CatalogImage: Codable, Sendable, Equatable {
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

// MARK: - Semantic comparison & merge helpers

nonisolated extension Catalog {
    /// Total number of images across the whole tree.
    var totalImageCount: Int {
        var count = 0
        for year in years.values {
            for month in year.months.values {
                for day in month.days.values {
                    for album in day.albums.values {
                        count += album.images.count
                    }
                }
            }
        }
        return count
    }

    /// Semantic equality that ignores `lastUpdated` and the ordering of each
    /// album's images. Two catalogs that hold the same albums and images are
    /// equal even when their JSON bytes differ (formatting, key order, array
    /// order, encoder version). Sync relies on this — comparing raw bytes made
    /// loop-prevention depend on the exact encoder configuration, so a
    /// formatting change (or a mixed-version fleet) re-opened the write loop.
    func contentEquals(_ other: Catalog) -> Bool {
        normalizedYears() == other.normalizedYears()
    }

    /// `years` in a canonical form for content comparison: each album's images
    /// sorted by sha256 (order-insensitive), and each album's `addedAt` floored
    /// to whole seconds. catalog.json persists second-precision ISO-8601 dates,
    /// so a higher-precision in-memory `addedAt` must not read as different
    /// content from its round-tripped form — otherwise every sync sees a
    /// spurious change and rewrites the target forever.
    private func normalizedYears() -> [String: CatalogYear] {
        func floorToSecond(_ date: Date) -> Date {
            Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        }
        var result = years
        for (y, var year) in result {
            for (m, var month) in year.months {
                for (d, var day) in month.days {
                    for (name, var album) in day.albums {
                        album.images.sort { $0.sha256 < $1.sha256 }
                        album.addedAt = floorToSecond(album.addedAt)
                        day.albums[name] = album
                    }
                    month.days[d] = day
                }
                year.months[m] = month
            }
            result[y] = year
        }
        return result
    }
}

nonisolated extension CatalogImage {
    /// Deterministically combine two catalog entries for the same image (same
    /// sha256) so that `a.reconciled(with: b)` and `b.reconciled(with: a)`
    /// produce identical results. Without a commutative merge, two Macs that
    /// hold different values for one image — e.g. a `b2FileId` reassigned by a
    /// heal on one Mac — never converge, and each sync re-pushes its own
    /// version: an endless cross-Mac write loop the byte-level echo check
    /// cannot break.
    func reconciled(with other: CatalogImage) -> CatalogImage {
        func pick(_ a: String, _ b: String) -> String { a >= b ? a : b }
        func pick(_ a: String?, _ b: String?) -> String? {
            switch (a, b) {
            case (nil, nil): nil
            case let (x?, nil): x
            case let (nil, y?): y
            case let (x?, y?): x >= y ? x : y
            }
        }
        func pick(_ a: Int64?, _ b: Int64?) -> Int64? {
            switch (a, b) {
            case (nil, nil): nil
            case let (x?, nil): x
            case let (nil, y?): y
            case let (x?, y?): Swift.max(x, y)
            }
        }
        return CatalogImage(
            filename: pick(filename, other.filename),
            sha256: sha256,
            sizeBytes: Swift.max(sizeBytes, other.sizeBytes),
            par2Filename: pick(par2Filename, other.par2Filename),
            b2FileId: pick(b2FileId, other.b2FileId),
            encryptionAlgorithm: pick(encryptionAlgorithm, other.encryptionAlgorithm),
            encryptionKeyId: pick(encryptionKeyId, other.encryptionKeyId),
            encryptionNonce: pick(encryptionNonce, other.encryptionNonce),
            encryptedSizeBytes: pick(encryptedSizeBytes, other.encryptedSizeBytes)
        )
    }
}

// MARK: - Encoder/Decoder Helpers

nonisolated extension Catalog {
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
