import Foundation
import SwiftUI

#if os(macOS)
import AppKit

/// Platform-native image type.
typealias PlatformImage = NSImage

extension Image {
    /// Create a SwiftUI `Image` from a platform-native image.
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}

#else
import UIKit

/// Platform-native image type.
typealias PlatformImage = UIImage

extension UIImage {
    /// Match NSImage's `init(contentsOf:)` API on iOS.
    convenience init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }
}

extension Image {
    /// Create a SwiftUI `Image` from a platform-native image.
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}
#endif
