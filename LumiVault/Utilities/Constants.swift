import Foundation
import SwiftUI

enum Constants {
    // MARK: - Design
    enum Design {
        static let accentColor = Color(red: 0.329, green: 0.580, blue: 0.871) // Blue accent

        static let monoLargeTitle = Font.system(.largeTitle, design: .monospaced).weight(.medium)
        static let monoTitle = Font.system(.title, design: .monospaced).weight(.medium)
        static let monoTitle2 = Font.system(.title2, design: .monospaced).weight(.medium)
        static let monoTitle3 = Font.system(.title3, design: .monospaced).weight(.medium)
        static let monoHeadline = Font.system(.headline, design: .monospaced)
        static let monoSubheadline = Font.system(.subheadline, design: .monospaced)
        static let monoBody = Font.system(.body, design: .monospaced)
        static let monoCaption = Font.system(.caption, design: .monospaced)
        static let monoCaption2 = Font.system(.caption2, design: .monospaced)
    }

    // MARK: - Paths
    enum Paths {
        static let defaultCatalog = "~/.lumivault/catalog.json"
        nonisolated static let iCloudContainer = "iCloud.app.lumivault"
        nonisolated static let debugSyncFallback = "~/.lumivault/catalog.json"
    }

    // MARK: - Thumbnails
    enum Thumbnails {
        static let gridSize = 256
        static let listSize = 64
        static let heicQuality: Float = 0.65
        static let memoryCacheLimit = 128 * 1024 * 1024 // 128 MB
        static let diskCacheLimit: Int64 = 2 * 1024 * 1024 * 1024 // 2 GB
    }

    // MARK: - Deduplication
    enum Dedup {
        static let nearDuplicateThreshold = 5 // Hamming distance
    }

    // MARK: - App
    enum App {
        static let name = "LumiVault"
        static let catalogVersion = 1
    }
}
