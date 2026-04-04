import Foundation
import CryptoKit

actor HasherService {
    private static let bufferSize = 1024 * 1024 // 1 MB chunks

    func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: Self.bufferSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func sha256AndSize(of url: URL) throws -> (hash: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        var hasher = SHA256()
        var totalSize: Int64 = 0

        while true {
            let chunk = handle.readData(ofLength: Self.bufferSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            totalSize += Int64(chunk.count)
        }

        let digest = hasher.finalize()
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return (hash, totalSize)
    }
}
