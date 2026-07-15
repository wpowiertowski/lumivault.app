# CLAUDE.md — LumiVault

## Project Overview

LumiVault is a native macOS 26 photo archiving app built with SwiftUI, SwiftData, and Swift 6.2. It imports albums from Apple Photos, deduplicates via SHA-256, generates PAR2 error correction, mirrors to external volumes, uploads to Backblaze B2, and syncs catalog.json via iCloud.

## Build & Run

```bash
# Build with Swift Package Manager
swift build

# Run tests
swift test

# Generate Xcode project (requires xcodegen)
xcodegen generate

# Build via Xcode
xcodebuild -project LumiVault.xcodeproj -scheme LumiVault -configuration Debug build
```

The `.xcodeproj` is generated from `project.yml` by `xcodegen generate` and committed to the repo. Regenerate and commit it after any structural change (added/removed/moved files or `project.yml` edits).

## Architecture

- **Swift 6.2** with strict concurrency and `@MainActor` default isolation
- **Zero third-party dependencies** — only Apple frameworks
- Services are **actors** (CatalogService, HasherService, ThumbnailService, B2Service, etc.)
- Views use **@Observable** and **@Query** (SwiftData), not ObservableObject/Combine
- Codable conformances are MainActor-isolated due to default isolation — decode/encode via `MainActor.run {}` when called from non-MainActor actors. Exception: the `Catalog` structs (Catalog.swift) are `nonisolated` so sync/backup can encode/decode and write sidecars off the main thread — a full-catalog encode on the MainActor caused visible UI hangs
- Use `nonisolated` for static utility methods that need to be called across isolation boundaries (e.g., PerceptualHash, BookmarkResolver)

## Code Conventions

- **No third-party packages** — this is a hard requirement (goal G5 in ARCHITECTURE-macOS.md)
- **macOS only** — no `#if os(iOS)` conditionals needed
- Monospaced fonts from `Constants.Design` for all UI text
- Accent color via `Constants.Design.accentColor`
- SwiftData models: `ImageRecord`, `AlbumRecord`, `VolumeRecord`
- Catalog JSON schema changes must stay backwards-compatible (older catalogs must still decode)

## Key Files

- `Package.swift` — SPM config, source of truth for dependencies and Swift settings
- `project.yml` — XcodeGen config, generates the .xcodeproj
- `LumiVault/Info.plist` — privacy descriptions (Photos library access)
- `LumiVault/LumiVault.entitlements` — sandbox, file access, bookmarks, Photos, network
- `LumiVault/Models/Catalog.swift` — Codable structs mirroring catalog.json (keep schema backwards-compatible)

## Common Pitfalls

- `ModelContext` is not Sendable — don't pass it across actor boundaries. Keep SwiftData operations on MainActor.
- When adding new Codable types, their conformances are MainActor-isolated by default. Use `await MainActor.run { }` to encode/decode from actor contexts — or mark the type `nonisolated` (like the `Catalog` structs) when it's a plain value type that services must encode off-main.
- `DuplicateResult` enum cannot be Sendable because it contains `ImageRecord` (a SwiftData @Model class).
- XcodeGen: use `platform: macOS` (scalar), not `platform: [macOS]` (array) — array form appends `_macOS` suffix to target names and breaks test dependencies.
- Always add privacy usage descriptions to Info.plist before accessing protected resources (Photos, etc.).

## Testing

Tests use Swift Testing (`import Testing`, `@Test`, `@Suite`). Test suite is `@MainActor` because Codable conformances require it under default isolation.

```bash
swift test                                    # Run all tests
swift test --filter LumiVaultTests            # Run specific suite
xcodebuild test -project LumiVault.xcodeproj -scheme LumiVaultTests -destination 'platform=macOS'
```

## Approach Guidelines

### Act Directly

- Bug fixes, small UI changes, single-file modifications
- Clear, well-defined tasks with obvious implementation

### Use Plan Mode

- New features affecting multiple files or services
- Architectural changes or refactors
- Changes to the catalog.json format (backwards-compatibility risk)
- New service actors or view hierarchies

### Avoid Over-Engineering

- No abstractions for one-time operations
- No speculative features or "just in case" code
- Three similar lines > premature abstraction
- No error handling for impossible scenarios
- Trust SwiftUI/SwiftData framework guarantees

## Git Workflow

### Commits
- Only commit when explicitly asked
- Add specific files, never `git add .` or `git add -A`
- Concise message focusing on "why", end with `Co-Authored-By` line
- Never skip hooks, never force push to main

### Releases
When asked to create a release:
1. Update version in `project.yml` (`MARKETING_VERSION`) and `Package.swift` if needed
2. Create a commit summarizing changes since last release
3. Tag with `v{version}` (e.g., `v1.0.0`)
4. Push commit and tag to origin

## Project-Specific Rules

- **catalog.json changes require extra care** — the catalog is synced via iCloud and re-read across app versions, so any schema change must be backwards-compatible (older catalogs must still decode).
- **Entitlements must match between Debug and Release** — both `.entitlements` files should stay in sync unless there's a specific reason to diverge.
- **Regenerate .xcodeproj after structural changes** — if you add/remove/move Swift files or change `project.yml`, run `xcodegen generate` and verify the build.
- **Privacy descriptions in Info.plist** — any new framework requiring user permission (e.g., Contacts, Location) needs a usage description added *before* the code ships.
