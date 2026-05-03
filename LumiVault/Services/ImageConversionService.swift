import Foundation
import AppKit
import ImageIO

enum ImageConversionService {
    nonisolated static func convertImage(
        asset: ImportedAsset,
        format: ImageFormat,
        quality: Double,
        maxDimension: MaxDimension,
        staging: URL
    ) -> ImportedAsset {
        guard let image = NSImage(contentsOf: asset.fileURL),
              let srcRep = image.representations.first else { return asset }

        // pixelsWide/pixelsHigh return -1 when unknown (HEIC, RAW, etc.)
        // Fall back to the point-based image size in that case.
        let pixelWidth = srcRep.pixelsWide > 0 ? CGFloat(srcRep.pixelsWide) : image.size.width
        let pixelHeight = srcRep.pixelsHigh > 0 ? CGFloat(srcRep.pixelsHigh) : image.size.height

        guard pixelWidth > 0, pixelHeight > 0 else { return asset }

        var targetWidth = pixelWidth
        var targetHeight = pixelHeight
        if case .capped(let maxPx) = maxDimension {
            let maxSide = max(pixelWidth, pixelHeight)
            if maxSide > CGFloat(maxPx) {
                let scale = CGFloat(maxPx) / maxSide
                targetWidth = (pixelWidth * scale).rounded()
                targetHeight = (pixelHeight * scale).rounded()
            }
        }

        let needsResize = targetWidth != pixelWidth || targetHeight != pixelHeight
        let needsConversion = format == .jpeg || format == .heic

        guard needsResize || needsConversion else { return asset }

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetWidth),
            pixelsHigh: Int(targetHeight),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return asset }

        bitmapRep.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        image.draw(in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
                   from: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height),
                   operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        let outputData: Data?
        let outputFilename: String
        let stem = (asset.originalFilename as NSString).deletingPathExtension

        switch format {
        case .jpeg:
            outputData = encodeCGImage(bitmapRep.cgImage.flatMap(strippingAlpha),
                                       type: "public.jpeg", quality: quality)
            outputFilename = stem + ".jpg"
        case .heic:
            outputData = encodeCGImage(bitmapRep.cgImage.flatMap(strippingAlpha),
                                       type: "public.heic", quality: quality)
            outputFilename = stem + ".heic"
        case .original:
            outputData = bitmapRep.representation(using: .png, properties: [:])
            outputFilename = asset.originalFilename
        }

        guard let data = outputData else { return asset }

        let convertedDir = staging.appendingPathComponent("converted", isDirectory: true)
        try? FileManager.default.createDirectory(at: convertedDir, withIntermediateDirectories: true)
        let outputURL = convertedDir.appendingPathComponent(outputFilename)
        do {
            try data.write(to: outputURL, options: .atomic)
            return ImportedAsset(
                fileURL: outputURL,
                originalFilename: outputFilename,
                creationDate: asset.creationDate
            )
        } catch {
            return asset
        }
    }

    nonisolated private static func encodeCGImage(_ image: CGImage?, type: String, quality: Double) -> Data? {
        guard let image else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Create a copy of a CGImage with alpha stripped (noneSkipLast).
    nonisolated private static func strippingAlpha(_ source: CGImage) -> CGImage? {
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
}
