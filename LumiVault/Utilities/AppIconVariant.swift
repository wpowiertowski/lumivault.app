import SwiftUI

/// The available app icon variants. Each variant ships its own `.icon` bundle and a
/// matching accent color extracted from the icon's background gradient.
enum AppIconVariant: String, CaseIterable, Identifiable, Sendable {
    case original
    case cobalt
    case forest
    case magenta

    nonisolated var id: String { rawValue }

    /// Bundle resource name (the `.icon` folder name without extension).
    nonisolated var resourceName: String {
        switch self {
        case .original: return "AppIcon"
        case .cobalt: return "AppIcon-Cobalt"
        case .forest: return "AppIcon-Forest"
        case .magenta: return "AppIcon-Magenta"
        }
    }

    /// Primary label shown in the settings picker.
    nonisolated var displayName: String {
        switch self {
        case .original: return "Original"
        case .cobalt: return "Cobalt"
        case .forest: return "Forest"
        case .magenta: return "Magenta"
        }
    }

    /// Color family descriptor shown as a secondary label.
    nonisolated var colorName: String {
        switch self {
        case .original: return "Orange"
        case .cobalt: return "Blue"
        case .forest: return "Green"
        case .magenta: return "Purple"
        }
    }

    /// Dominant color sampled from the icon's background gradient.
    nonisolated var accentColor: Color {
        switch self {
        case .original: return Color(.displayP3, red: 1.000, green: 0.439, blue: 0.000)
        case .cobalt:   return Color(.displayP3, red: 0.227, green: 0.459, blue: 1.000)
        case .forest:   return Color(.displayP3, red: 0.000, green: 0.600, blue: 0.122)
        case .magenta:  return Color(.displayP3, red: 0.690, green: 0.337, blue: 1.000)
        }
    }

    nonisolated static let defaultsKey = "appIconVariant"

    /// Current selection from UserDefaults; defaults to `.original`.
    nonisolated static var current: AppIconVariant {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? AppIconVariant.original.rawValue
        return AppIconVariant(rawValue: raw) ?? .original
    }
}
