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
    private let cacheRoot: URL
    private let memoryCache = NSCache<NSString, NSImage>()

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheRoot = caches.appendingPathComponent("app.lumivault/thumbnails", isDirectory: true)
        memoryCache.totalCostLimit = 128 * 1024 * 1024 // 128 MB
    }

    // MARK: - Public API

    func thumbnail(for sha256: String, size: ThumbnailSize) -> NSImage? {
        let key = NSString(string: "\(size.rawValue)/\(sha256)")

        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        let fileURL = cacheURL(for: sha256, size: size)
        guard let image = NSImage(contentsOf: fileURL) else { return nil }

        memoryCache.setObject(image, forKey: key, cost: image.tiffRepresentation?.count ?? 0)
        return image
    }

    func generateThumbnail(for fileURL: URL, sha256: String) throws {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw ThumbnailError.unreadableSource
        }

        for size in [ThumbnailSize.grid, .list] {
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: size.rawValue,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw ThumbnailError.generationFailed
            }

            let destURL = cacheURL(for: sha256, size: size)
            try FileManager.default.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, "public.heic" as CFString, 1, nil) else {
                throw ThumbnailError.writeFailed
            }

            let destOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.65]
            CGImageDestinationAddImage(dest, cgImage, destOptions as CFDictionary)

            guard CGImageDestinationFinalize(dest) else {
                throw ThumbnailError.writeFailed
            }
        }
    }

    // MARK: - Warm Up

    func warmUp(hashes: [(sha256: String, url: URL)]) {
        for item in hashes {
            try? self.generateThumbnail(for: item.url, sha256: item.sha256)
        }
    }

    // MARK: - Private

    private func cacheURL(for sha256: String, size: ThumbnailSize) -> URL {
        let prefix = String(sha256.prefix(2))
        return cacheRoot
            .appendingPathComponent("\(size.rawValue)", isDirectory: true)
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent("\(sha256).heic")
    }

    enum ThumbnailError: Error {
        case unreadableSource
        case generationFailed
        case writeFailed
    }
}
