[![Build](https://github.com/wpowiertowski/lumivault.app/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/wpowiertowski/lumivault.app/actions?query=branch%3Amain)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Swift 6.2](https://img.shields.io/badge/swift-6.2-F05138.svg)](https://swift.org)
[![macOS 26](https://img.shields.io/badge/macOS-26-000000.svg)](https://developer.apple.com/macos/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-blue.svg)](https://developer.apple.com/swiftui/)
[![SwiftData](https://img.shields.io/badge/SwiftData-blue.svg)](https://developer.apple.com/swiftdata/)

# LumiVault

Your photos, preserved forever. Native macOS archiving with iCloud sync, deduplication, and built-in error correction.

---

## Overview

LumiVault is a native macOS 26 application for long-term photo archiving. It reimagines the existing PhotoVault CLI as a first-class desktop experience built entirely with Apple frameworks — zero third-party dependencies.

Photos are organized into date-based albums, deduplicated across multiple external volumes, protected with Reed-Solomon error correction, and synced via iCloud. The app reads and writes the same `catalog.json` format as the CLI tool, so both workflows can coexist.

## Features

- **Apple Photos Import** — browse and select albums from your Photos library, export originals via PhotoKit, and archive them in one step
- **Backblaze B2 Cloud Upload** — upload photos and PAR2 recovery data to B2 cloud storage via the REST API with SHA-1 verification
- **iCloud Catalog Sync** — catalog.json syncs across devices via iCloud Drive with conflict-free merge (union by SHA-256, newest timestamp wins)
- **Thumbnail Generation** — HEIC/RAW/CR2/CR3/NEF/ARW/DNG support with a multi-resolution cache (256px grid, 64px list) keyed by content hash
- **Deduplication** — exact (SHA-256) and near-duplicate (perceptual hash dHash) detection across all connected volumes
- **Multi-Volume Mirroring** — mirror albums to multiple external drives with security-scoped bookmarks for persistent access
- **Reed-Solomon Error Correction** — GF(2^8) Vandermonde-matrix redundancy with PAR2-compatible file format, including single-block repair with cross-verification
- **Integrity Verification** — background checks surface corruption by re-hashing files against stored SHA-256 digests
- **Drag & Drop Import** — native file import via `UniformTypeIdentifiers` with image-type filtering
- **Settings** — configure external volumes, iCloud sync, and Backblaze B2 credentials

## Technology Stack

| Layer           | Framework                                          |
| --------------- | -------------------------------------------------- |
| UI              | SwiftUI (NavigationSplitView, @Observable)         |
| Data            | SwiftData                                          |
| Photos Import   | PhotoKit (Photos, PhotosUI)                        |
| Cloud Sync      | iCloud Drive via NSFileCoordinator                 |
| Cloud Storage   | URLSession + Backblaze B2 REST API                 |
| Image Pipeline  | Core Image, ImageIO                                |
| Hashing         | CryptoKit (SHA-256, SHA-1)                         |
| Redundancy      | Custom GF(2^8) Reed-Solomon (Vandermonde matrix)   |
| Concurrency     | Swift Concurrency (async/await, TaskGroup, actors) |

## Architecture

```text
┌──────────────────────────────────────────────────────────┐
│                        SwiftUI Shell                     │
│  ┌──────────┐  ┌────────────┐  ┌──────────────────────┐  │
│  │ Sidebar  │  │ Grid View  │  │ Detail / Inspector   │  │
│  │ (Years/  │  │ (Thumbnails│  │ (EXIF, hash, par2,   │  │
│  │  Albums) │  │  LazyVGrid)│  │  storage locations)  │  │
│  └──────────┘  └────────────┘  └──────────────────────┘  │
└──────────────────────┬───────────────────────────────────┘
                       │
          ┌────────────┴────────────┐
          │     Domain Services     │
          │  (actors / @Observable) │
          ├─────────────────────────┤
          │ CatalogService          │  read/write/merge catalog.json
          │ PhotosImportService     │  PhotoKit album export
          │ ThumbnailService        │  generate + NSCache (128 MB)
          │ DeduplicationService    │  SHA-256 + perceptual hash index
          │ RedundancyService       │  Reed-Solomon ECC encode/verify/repair
          │ B2Service               │  Backblaze B2 cloud upload
          │ SyncService             │  iCloud push/pull via NSFileCoordinator
          │ VolumeService           │  external disk discovery/bookmarks
          │ IntegrityService        │  verification sweeps
          │ ExportCoordinator       │  orchestrates full export pipeline
          └────────────┬────────────┘
                       │
          ┌────────────┴────────────┐
          │     Persistence Layer   │
          ├─────────────────────────┤
          │ SwiftData ModelContext   │  local index
          │ catalog.json (Codable)  │  portable JSON catalog
          │ NSFileCoordinator       │  safe concurrent file access
          └─────────────────────────┘
```

## Project Structure

```text
LumiVault/
├── App/                  App entry point, ContentView, menu commands
├── Models/               Codable catalog structs, SwiftData models, B2 credentials
├── Services/             Actor-based domain services + export coordinator
│   └── Persistence/      SwiftData container factory
├── Views/
│   ├── Sidebar/          Year-grouped album list + volume status popover
│   ├── Grid/             LazyVGrid thumbnail browser
│   ├── Detail/           Full-resolution preview + metadata inspector
│   ├── Import/           Drag-and-drop file import with progress
│   ├── PhotosImport/     Photos library album picker + export wizard
│   ├── Settings/         General, Volumes, iCloud, B2 configuration
│   └── Shared/           Reusable components (EmptyStateView)
├── Utilities/            Perceptual hashing, file coordination, bookmarks
└── Resources/            Asset catalog
```

## Migration from CLI

LumiVault reads and writes the same `catalog.json` format as the PhotoVault CLI. In Settings, use the "Detect Existing" button to locate `~/.photovault/catalog.json` and import it into the app's local index. Both tools can coexist — changes made in either are merged on sync.

## Testing

38 tests across 7 suites covering core logic:

```bash
swift test                                    # Run all tests
swift test --filter CatalogTests              # Run specific suite
```

| Suite                      | Tests | Coverage                                                          |
| -------------------------- | ----- | ----------------------------------------------------------------- |
| CatalogTests               | 5     | Codable round-trip, optional fields, file I/O, snake_case keys    |
| CatalogServiceMergeTests   | 5     | Disjoint merge, SHA union, new albums, timestamps, deduplication  |
| HasherServiceTests         | 4     | Known hashes, empty file, size tracking, method consistency       |
| RedundancyServiceTests     | 8     | PAR2 generate/verify, corrupt-and-repair round-trip, edge cases   |
| PerceptualHashTests        | 7     | Hamming distance, symmetry, thresholds, invalid input             |
| IntegrityServiceTests      | 4     | Hash match/mismatch, missing files, batch size                    |
| SwiftDataModelTests        | 5     | Relationships, defaults, Codable support types                    |

## Requirements

- macOS 26 or later
- Xcode 26 or later (to build from source)
- iCloud account (optional, for catalog sync)
- Backblaze B2 account (optional, for cloud uploads)

## License

This project is licensed under the [MIT License](LICENSE).
