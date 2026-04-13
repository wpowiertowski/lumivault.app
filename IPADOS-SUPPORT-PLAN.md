# iPadOS 26 Support — Implementation Plan

## Overview

Add iPadOS 26 as a supported platform alongside macOS 26. The goal is to share
maximum code between platforms using `#if os()` conditionals at the boundaries,
a thin platform-abstraction layer for image types, and SwiftUI's built-in
cross-platform file-picker modifiers to replace `NSOpenPanel`.

---

## Phase 1: Platform Abstraction Layer

### 1.1 Create `LumiVault/Utilities/PlatformImage.swift`

Introduce typealiases and a small extension so every view and service can work
with a single `PlatformImage` type:

```swift
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension PlatformImage {
    /// Unified constructor from raw Data.
    convenience init?(platformData data: Data) { self.init(data: data) }
}

extension Image {
    /// Unified SwiftUI Image from a platform-native image.
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
```

**Files that will adopt `PlatformImage`:**

| File | Current API | Change |
|---|---|---|
| `ThumbnailService.swift` | `NSImage`, `NSCache<NSString, NSImage>` | → `PlatformImage`, `NSCache<NSString, PlatformImage>` |
| `PhotoGridItem.swift` | `@State var thumbnail: NSImage?`, `Image(nsImage:)` | → `PlatformImage?`, `Image(platformImage:)` |
| `PhotoDetailView.swift` | `@State var fullImage: NSImage?`, `NSImage(contentsOf:)`, `Image(nsImage:)` | → `PlatformImage?`, `PlatformImage(contentsOf:)`, `Image(platformImage:)` |
| `NearDuplicatesView.swift` | `@State var thumbnail: NSImage?`, `Image(nsImage:)` | → same pattern |
| `PhotosExportSheet.swift` | `@State var thumbnail: NSImage?`, `Image(nsImage:)` | → same pattern |

### 1.2 Create `LumiVault/Utilities/PlatformHelpers.swift`

Small helpers for APIs that differ between platforms:

```swift
import Foundation

enum PlatformHelpers {
    /// Expand tilde in path strings (replaces NSString.expandingTildeInPath).
    nonisolated static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Open a URL in the system browser / settings app.
    nonisolated static func openURL(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        Task { @MainActor in UIApplication.shared.open(url) }
        #endif
    }

    /// Reveal a file in Finder (macOS) or no-op on iPadOS.
    nonisolated static func revealInFinder(path: String) {
        #if os(macOS)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        #endif
    }

    /// Open the Settings app / System Settings.
    nonisolated static func openSettings() {
        #if os(macOS)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
        #else
        Task { @MainActor in UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
        #endif
    }
}
```

---

## Phase 2: App Lifecycle & Entry Point

### 2.1 `LumiVaultApp.swift`

- Wrap `AppActivationDelegate` and `@NSApplicationDelegateAdaptor` in `#if os(macOS)`
- Wrap `.defaultSize()` and `.windowResizability()` in `#if os(macOS)`
- Wrap `Settings { }` scene in `#if os(macOS)` (iPadOS uses in-app settings)
- Wrap `ImportFromPhotosCommands` in `#if os(macOS)` (iPadOS has no menu bar)

### 2.2 `ImportFromPhotosCommands.swift`

- Wrap entire file body in `#if os(macOS)` — commands are a macOS-only concept.
  The notification-based trigger (`NotificationCenter.default.post`) stays for both.

---

## Phase 3: Replace NSOpenPanel → SwiftUI `.fileImporter()`

Every `NSOpenPanel` call becomes a SwiftUI `.fileImporter()` or `.fileExporter()`
modifier. On macOS these still produce the native NSOpenPanel under the hood.
On iPadOS they produce the document picker.

### Affected files and changes:

| File | Lines | Panel Purpose | Replacement |
|---|---|---|---|
| `ContentView.swift` | 372-376 | Restore catalog from file | `.fileImporter(isPresented:allowedContentTypes:[.json])` |
| `ContentView.swift` | 382-386 | Restore catalog from volume | `.fileImporter(isPresented:allowedContentTypes:[.folder])` |
| `SidebarView.swift` | 132-138 | Pick directory | `.fileImporter(isPresented:allowedContentTypes:[.folder])` |
| `ImportSheet.swift` | 108-115 | Pick image files | `.fileImporter(isPresented:allowedContentTypes:allowsMultipleSelection:)` |
| `GeneralSettingsView.swift` | 82-85 | Browse catalog JSON | `.fileImporter` |
| `GeneralSettingsView.swift` | 98-102 | Restore from file | `.fileImporter` |
| `GeneralSettingsView.swift` | 107-111 | Restore from volume | `.fileImporter` |
| `VolumesSettingsView.swift` | 101-111 | Add volume directory | `.fileImporter` |

**Pattern:**
```swift
// Before (macOS-only):
Button("Choose...") {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    handleURL(url)
}

// After (cross-platform):
@State private var showingDirectoryPicker = false

Button("Choose...") { showingDirectoryPicker = true }
.fileImporter(isPresented: $showingDirectoryPicker, allowedContentTypes: [.folder]) { result in
    guard case .success(let url) = result else { return }
    handleURL(url)
}
```

---

## Phase 4: Volume & Bookmark Handling

### 4.1 `VolumeService.swift`

- `discoverMountedVolumes()`: Wrap in `#if os(macOS)` — this API doesn't
  enumerate USB drives on iPadOS. On iPadOS, volume discovery happens through
  the file picker (user selects an external drive folder in Files app).
- `createBookmark()`: Use `.withSecurityScope` on macOS, `.minimalBookmark` on iOS.
- `resolveBookmark()`: Use `.withSecurityScope` on macOS, `.withoutUI` on iOS.
  Both platforms support `startAccessingSecurityScopedResource()`.

### 4.2 `BookmarkResolver.swift`

Same bookmark option changes:
```swift
nonisolated static func createBookmark(for url: URL) throws -> Data {
    #if os(macOS)
    let options: URL.BookmarkCreationOptions = .withSecurityScope
    #else
    let options: URL.BookmarkCreationOptions = .minimalBookmark
    #endif
    return try url.bookmarkData(options: options, ...)
}
```

---

## Phase 5: Export Coordinators (HEIF Conversion)

### 5.1 `ExportCoordinator.swift` & `PipelinedExportCoordinator.swift`

Both files use `NSImage` → `NSBitmapImageRep` → `NSGraphicsContext` for
HEIF conversion. Replace with a cross-platform `CGImage`-based pipeline:

```swift
// Cross-platform HEIF conversion using ImageIO + CoreImage (no AppKit/UIKit)
func convertToHEIF(sourceURL: URL, destURL: URL, maxDimension: Int) throws {
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ... }

    // Resize with CIImage
    let ciImage = CIImage(cgImage: cgImage)
    let scale = Double(maxDimension) / max(Double(cgImage.width), Double(cgImage.height))
    let scaled = ciImage.transformed(by: .init(scaleX: scale, y: scale))

    // Write HEIF via CIContext
    let context = CIContext()
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    try context.writeHEIFRepresentation(of: scaled, to: destURL, format: .RGBA8, colorSpace: colorSpace)
}
```

This eliminates all `NSBitmapImageRep`, `NSGraphicsContext`, and `NSSize` usage.

---

## Phase 6: SyncService & iCloud

### 6.1 `SyncService.swift`

- `NSFileCoordinator` → available on both platforms (Foundation), **no change needed**
- `NSMetadataQuery` → available on both platforms (Foundation), **no change needed**
- `NSString.expandingTildeInPath` → `PlatformHelpers.expandTilde()` (cosmetic)

---

## Phase 7: PerceptualHash

### 7.1 `PerceptualHash.swift`

- Currently imports `AppKit` but doesn't use any AppKit APIs (only CoreImage/CIContext).
- Change: `import AppKit` → conditional import or just remove (CoreImage suffices).

---

## Phase 8: Platform Configuration

### 8.1 `Package.swift`

```swift
platforms: [
    .macOS(.v26),
    .iOS(.v26)
]
```

### 8.2 `project.yml`

Add iPadOS target alongside existing macOS targets:
```yaml
options:
  deploymentTarget:
    macOS: "26.0"
    iOS: "26.0"

targets:
  LumiVault-iPadOS:
    type: application
    platform: iOS
    sources: ...  # same source tree
    settings:
      base:
        TARGETED_DEVICE_FAMILY: 2  # iPad only
        SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD: false
```

### 8.3 Entitlements

Create `LumiVault/LumiVault.iOS.entitlements`:
```xml
com.apple.security.personal-information.photos-library  → YES
com.apple.developer.ubiquity-container-identifiers       → iCloud.app.lumivault
```

Note: iOS apps are always sandboxed, so no explicit sandbox entitlement.
File access and network access don't need entitlements on iOS.

### 8.4 `Info.plist`

No changes needed — `NSPhotoLibraryUsageDescription` works on both platforms.

---

## Phase 9: UI Adaptations

### 9.1 `ContentView.swift`

- Wrap `.frame(minWidth: 820, minHeight: 500)` in `#if os(macOS)`
- iPadOS gets natural NavigationSplitView sizing

### 9.2 Settings Access on iPadOS

Since iPadOS has no `Settings { }` scene, add an in-app settings sheet:
- Add a toolbar gear button that presents `SettingsView()` as a `.sheet()`
- Wrap in `#if os(iOS)` so macOS keeps its native Settings window

### 9.3 `AlbumExportSheet.swift`

- `NSWorkspace.shared.selectFile(...)` → `PlatformHelpers.revealInFinder()`
  (no-op on iPadOS, or show a share sheet alternative)

### 9.4 `PhotosAlbumPicker.swift`

- `NSWorkspace.shared.open(...)` → `PlatformHelpers.openSettings()`

### 9.5 `PhotosExportSheet.swift`

- `NSApp.sendAction(Selector(("showSettingsWindow:")), ...)` → wrap in
  `#if os(macOS)`, on iPadOS present settings sheet via binding

---

## Phase 10: Build Verification

1. `swift build` — verify SPM compiles for macOS
2. `swift test` — verify existing tests pass
3. Manual: verify `xcodegen generate` produces valid project with both targets

---

## File Change Summary

| Category | Files Created | Files Modified |
|---|---|---|
| New utilities | 2 (`PlatformImage.swift`, `PlatformHelpers.swift`) | — |
| New entitlements | 1 (`LumiVault.iOS.entitlements`) | — |
| Platform config | — | 2 (`Package.swift`, `project.yml`) |
| App lifecycle | — | 2 (`LumiVaultApp.swift`, `ImportFromPhotosCommands.swift`) |
| Services | — | 5 (`ThumbnailService`, `VolumeService`, `ExportCoordinator`, `PipelinedExportCoordinator`, `PerceptualHash`) |
| Utilities | — | 2 (`BookmarkResolver`, `Constants` if needed) |
| Views | — | 11 (`ContentView`, `SidebarView`, `ImportSheet`, `GeneralSettingsView`, `VolumesSettingsView`, `PhotoGridItem`, `PhotoDetailView`, `NearDuplicatesView`, `PhotosExportSheet`, `PhotosAlbumPicker`, `AlbumExportSheet`) |
| Sync | — | 2 (`SyncService`, `SyncCoordinator`) |
| **Total** | **3 new** | **~24 modified** |

---

## USB Drive Naming — Cross-Platform Compatibility

The volume **label** (e.g., "LumiVault-Archive") is a filesystem-level property
stored in the partition metadata. Both macOS and iPadOS read the identical label.
Only the **mount point path** differs:

- macOS: `/Volumes/LumiVault-Archive/`
- iPadOS: `/private/var/mobile/Library/LiveFiles/.../LumiVault-Archive/`

Since LumiVault uses URL-based access + security-scoped bookmarks (not hardcoded
paths), and `catalog.json` references volumes by label/ID (not mount point), the
same USB drive works interchangeably between macOS and iPadOS.

---

## Execution Order

1. Phase 1 — Platform abstraction (unblocks everything else)
2. Phase 8.1 — Package.swift platform declaration (enables compile-checking)
3. Phase 7 — PerceptualHash (trivial, quick win)
4. Phase 2 — App lifecycle
5. Phase 1 adoptions — Migrate all NSImage → PlatformImage across views/services
6. Phase 3 — Replace NSOpenPanel → fileImporter
7. Phase 4 — Volume & bookmark handling
8. Phase 5 — Export coordinators HEIF conversion
9. Phase 6 — SyncService/SyncCoordinator tilde expansion
10. Phase 9 — UI adaptations (frame sizes, settings access)
11. Phase 8.2–8.4 — project.yml, entitlements, Info.plist
12. Phase 10 — Build verification
