import Foundation
import AppKit
import ImageIO
import CoreImage
import SwiftUI

enum ThumbnailSize: Int, Sendable {
    case grid = 256
    case list = 64
}

// MARK: - Environment Key

private struct ThumbnailServiceKey: EnvironmentKey {
    static let defaultValue: ThumbnailService = ThumbnailService()
}

extension EnvironmentValues {
    var thumbnailService: ThumbnailService {
        get { self[ThumbnailServiceKey.self] }
        set { self[ThumbnailServiceKey.self] = newValue }
    }
}

actor ThumbnailService {
    private let storageRoot: URL
    private let memoryCache = NSCache<NSString, NSImage>()

    init() {
        self.storageRoot = URL.applicationSupportDirectory
            .appendingPathComponent("Thumbnails", isDirectory: true)
        memoryCache.totalCostLimit = 128 * 1024 * 1024 // 128 MB
    }

    // MARK: - Public API

    func thumbnail(for sha256: String, size: ThumbnailSize) -> NSImage? {
        let key = NSString(string: "\(size.rawValue)/\(sha256)")

        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        let fileURL = storageURL(for: sha256, size: size)
        guard let image = NSImage(contentsOf: fileURL) else { return nil }

        memoryCache.setObject(image, forKey: key, cost: image.tiffRepresentation?.count ?? 0)
        return image
    }

    func generateThumbnail(for fileURL: URL, sha256: String) throws {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldAllowFloat: false]
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions as CFDictionary) else {
            throw ThumbnailError.unreadableSource
        }
        try writeThumbnails(from: source, sha256: sha256)
    }

    func generateThumbnail(from data: Data, sha256: String) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ThumbnailError.unreadableSource
        }
        try writeThumbnails(from: source, sha256: sha256)
    }

    /// Reads and decrypts an encrypted file, then generates thumbnails from the plaintext.
    /// File I/O runs on the thumbnail actor to avoid blocking the caller.
    func generateThumbnail(
        fromEncryptedFileAt fileURL: URL,
        nonce: Data,
        sha256: String,
        encryption: EncryptionService
    ) async throws {
        let ciphertext = try Data(contentsOf: fileURL)
        let plaintext = try await encryption.decryptData(ciphertext, nonce: nonce, sha256: sha256)
        try generateThumbnail(from: plaintext, sha256: sha256)
    }

    // MARK: - Removal

    func removeThumbnails(for sha256: String) {
        let fm = FileManager.default
        for size in [ThumbnailSize.grid, .list] {
            let key = NSString(string: "\(size.rawValue)/\(sha256)")
            memoryCache.removeObject(forKey: key)
            let fileURL = storageURL(for: sha256, size: size)
            try? fm.removeItem(at: fileURL)
        }
    }

    // MARK: - Private

    private func writeThumbnails(from source: CGImageSource, sha256: String) throws {
        for size in [ThumbnailSize.grid, .list] {
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: size.rawValue,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw ThumbnailError.generationFailed
            }

            let destURL = storageURL(for: sha256, size: size)
            try FileManager.default.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, "public.heic" as CFString, 1, nil) else {
                throw ThumbnailError.writeFailed
            }

            let opaqueImage = Self.strippingAlpha(cgImage) ?? cgImage
            let destOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.65]
            CGImageDestinationAddImage(dest, opaqueImage, destOptions as CFDictionary)

            guard CGImageDestinationFinalize(dest) else {
                throw ThumbnailError.writeFailed
            }

            let key = NSString(string: "\(size.rawValue)/\(sha256)")
            memoryCache.removeObject(forKey: key)
        }
    }

    private func storageURL(for sha256: String, size: ThumbnailSize) -> URL {
        let prefix = String(sha256.prefix(2))
        return storageRoot
            .appendingPathComponent("\(size.rawValue)", isDirectory: true)
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent("\(sha256).heic")
    }

    private static func strippingAlpha(_ source: CGImage) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: source.width,
            height: source.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return ctx.makeImage()
    }

    enum ThumbnailError: Error {
        case unreadableSource
        case generationFailed
        case writeFailed
    }
}
