import Foundation
import CoreImage

enum PerceptualHash {
    /// Compute a 64-bit difference hash (dHash) for the image at the given URL.
    /// Returns 8 bytes (64 bits) of hash data.
    nonisolated static func compute(for url: URL) throws -> Data {
        guard let ciImage = CIImage(contentsOf: url) else {
            throw PerceptualHashError.unreadable
        }

        let context = CIContext()

        // Resize to 9x8 grayscale (produces 8x8 = 64 gradient comparisons)
        let scaleX = 9.0 / ciImage.extent.width
        let scaleY = 8.0 / ciImage.extent.height
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Convert to grayscale
        let grayscale = scaled.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0
        ])

        // Render to pixel buffer
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        context.render(
            grayscale,
            toBitmap: &pixels,
            rowBytes: width,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .L8,
            colorSpace: colorSpace
        )

        // Compute dHash: compare adjacent pixels in each row
        var hashBits: UInt64 = 0
        for row in 0..<height {
            for col in 0..<(width - 1) {
                let index = row * width + col
                if pixels[index] < pixels[index + 1] {
                    hashBits |= 1 << (row * 8 + col)
                }
            }
        }

        var hash = hashBits
        return Data(bytes: &hash, count: 8)
    }

    /// Compute Hamming distance between two perceptual hashes.
    nonisolated static func hammingDistance(_ a: Data, _ b: Data) -> Int {
        guard a.count == 8, b.count == 8 else { return 64 }

        let hashA = a.withUnsafeBytes { $0.load(as: UInt64.self) }
        let hashB = b.withUnsafeBytes { $0.load(as: UInt64.self) }
        return (hashA ^ hashB).nonzeroBitCount
    }

    enum PerceptualHashError: Error {
        case unreadable
    }
}
