import AppKit
import SwiftUI

/// Tracks the user-selected app icon variant and applies it to the dock icon at runtime.
///
/// On macOS the `.icon` bundle in `Assets.xcassets` is locked at build time, so to switch
/// the dock icon we composite each variant's layer PNGs from its `.icon` resource folder
/// and assign the result to `NSApp.applicationIconImage`.
@MainActor
@Observable
final class AppearanceManager {
    var current: AppIconVariant {
        didSet {
            guard oldValue != current else { return }
            UserDefaults.standard.set(current.rawValue, forKey: AppIconVariant.defaultsKey)
            applyDockIcon()
        }
    }

    var accentColor: Color { current.accentColor }

    init() {
        self.current = AppIconVariant.current
        applyDockIcon()
    }

    /// Composite the current variant's layers and assign as the running app's dock icon.
    func applyDockIcon() {
        if let image = Self.renderedIcon(for: current, size: 1024) {
            NSApp?.applicationIconImage = image
        }
    }

    /// Composites the layered PNG assets in a variant's `.icon` resource bundle into a
    /// single rounded NSImage suitable for use as a dock icon or settings preview.
    static func renderedIcon(for variant: AppIconVariant, size: CGFloat) -> NSImage? {
        guard let bundleURL = Bundle.main.url(forResource: variant.resourceName, withExtension: "icon") else {
            return nil
        }
        let assetsURL = bundleURL.appendingPathComponent("Assets")

        // Drawing order: back to front. Matches the group order in icon.json
        // (excluding the mono-only `keyhole-dark.png` overlay).
        let layerNames = ["background.png", "layer3.png", "layer2.png", "layer1.png", "layer4.png", "layer5.png"]

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        // Apple's macOS app-icon corner ratio (~22.37% of edge length).
        let radius = size * 0.2237
        let mask = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        mask.setClip()

        for name in layerNames {
            let url = assetsURL.appendingPathComponent(name)
            guard let layer = NSImage(contentsOf: url) else { continue }
            layer.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        image.unlockFocus()
        return image
    }
}
