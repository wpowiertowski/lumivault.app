import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PlatformHelpers {
    /// Expand tilde in path strings.
    nonisolated static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Open a URL in the default browser or app.
    static func openURL(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// Reveal a file in Finder (macOS only — no-op on iPadOS).
    static func revealInFinder(path: String) {
        #if os(macOS)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        #endif
    }

    /// Open the system privacy settings for Photos access.
    static func openPhotosPrivacySettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    /// Open the app's Settings window (macOS) or no-op on iPadOS
    /// (iPadOS uses in-app settings sheet instead).
    static func openSettingsWindow() {
        #if os(macOS)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        #endif
    }
}
