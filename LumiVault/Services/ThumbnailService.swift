import Foundation
import AppKit
import ImageIO
import CoreImage
import SwiftUI
import AVFoundation

enum ThumbnailSize: Int, Sendable {
    case grid = 256
    case list = 64
}

/// Metadata read from a video while grabbing its poster frame — one
/// `AVURLAsset` load serves both the thumbnail and the record's fields.
nonisolated struct VideoProbe: Sendable {
    let durationSeconds: Double
    let pixelWidth: Int
    let pixelHeight: Int
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

    // MARK: - Video Poster Frames

    /// Grabs a poster frame from a video and writes it through the same SHA-keyed
    /// 256/64px HEIC cache as image thumbnails, so grid code needs no video branch.
    /// Sampled at min(1s, midpoint) to skip black lead-in frames.
    @discardableResult
    func generateVideoThumbnail(for fileURL: URL, sha256: String) async throws -> VideoProbe {
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let posterSeconds = duration.isFinite && duration > 0 ? Swift.min(1.0, duration / 2) : 0
        let time = CMTime(seconds: posterSeconds, preferredTimescale: 600)
        let (cgImage, _) = try await generator.image(at: time)

        // Encode the poster once, then reuse the image pipeline for 256/64 output.
        let posterData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(posterData, "public.heic" as CFString, 1, nil) else {
            throw ThumbnailError.writeFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ThumbnailError.writeFailed
        }
        try generateThumbnail(from: posterData as Data, sha256: sha256)

        // Display dimensions: natural size with the track's rotation applied.
        // Falls back to the (≤512px) poster dimensions if track load fails.
        var width = cgImage.width
        var height = cgImage.height
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let naturalSize = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
                width = Int(abs(rect.width).rounded())
                height = Int(abs(rect.height).rounded())
            }
        }

        return VideoProbe(
            durationSeconds: duration.isFinite ? duration : 0,
            pixelWidth: width,
            pixelHeight: height
        )
    }

    /// Video variant of `generateThumbnail(fromEncryptedFileAt:)`. Bounded by the
    /// encryption size cap — files above it are never stored encrypted.
    @discardableResult
    func generateVideoThumbnail(
        fromEncryptedFileAt fileURL: URL,
        nonce: Data,
        sha256: String,
        fileExtension: String,
        encryption: EncryptionService
    ) async throws -> VideoProbe {
        let ciphertext = try Data(contentsOf: fileURL)
        let plaintext = try await encryption.decryptData(ciphertext, nonce: nonce, sha256: sha256)
        return try await generateVideoThumbnail(
            fromPlaintext: plaintext, sha256: sha256, fileExtension: fileExtension
        )
    }

    /// Video variant of the encrypted regeneration path. `AVAsset` needs a URL,
    /// not `Data`, so the plaintext is staged to a temp file (original extension
    /// preserved for container sniffing) and removed before returning.
    @discardableResult
    func generateVideoThumbnail(
        fromPlaintext plaintext: Data,
        sha256: String,
        fileExtension: String
    ) async throws -> VideoProbe {
        let ext = fileExtension.isEmpty ? "mov" : fileExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-poster-\(sha256)")
            .appendingPathExtension(ext)
        try plaintext.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await generateVideoThumbnail(for: tempURL, sha256: sha256)
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
