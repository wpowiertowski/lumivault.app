[![Build](https://github.com/wpowiertowski/lumivault.app/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/wpowiertowski/lumivault.app/actions?query=branch%3Amain)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Swift 6.2](https://img.shields.io/badge/swift-6.2-F05138.svg)](https://swift.org)
[![macOS 26](https://img.shields.io/badge/macOS-26-000000.svg)](https://developer.apple.com/macos/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-blue.svg)](https://developer.apple.com/swiftui/)
[![SwiftData](https://img.shields.io/badge/SwiftData-blue.svg)](https://developer.apple.com/swiftdata/)

# LumiVault

Your photos, preserved forever. Native macOS archiving with Apple Photos integration, Reed-Solomon error correction, and iCloud sync.

---

## Overview

LumiVault is a native macOS 26 application for long-term photo archiving built entirely with Apple frameworks — zero third-party dependencies.

Photos are organized into date-based albums, deduplicated across multiple external volumes, protected with Reed-Solomon error correction, and synced via iCloud. The app reads and writes the same `catalog.json` format as the CLI tool, so both workflows can coexist.

## Features

- **Apple Photos Import** — browse, search, and sort albums from your Photos library; imports the current edited state (crops, filters, adjustments) via PhotoKit and archives in one step; supports multi-album batch import with per-album progress tracking
- **Reed-Solomon Error Correction** — standard PAR2 2.0 format with GF(2^16) Vandermonde-matrix Reed-Solomon coding, fully compatible with par2cmdline and other PAR2 tools; GPU-accelerated via Metal compute shaders (CPU fallback), adaptive block sizing for guaranteed 10% recovery, split file output (.par2 index + .vol0+N.par2 recovery volumes)
- **Integrity Verification & Auto-Repair** — re-hash files against stored SHA-256 digests to detect corruption; auto-repair by copying from a healthy volume or using PAR2 Reed-Solomon recovery; verify and repair individual albums or images via right-click context menus
- **Backblaze B2 Cloud Upload** — upload photos and PAR2 recovery data to B2 cloud storage via the REST API with SHA-1 verification; existence checks prevent duplicate uploads
- **Multi-Volume Mirroring** — mirror albums to multiple external drives with security-scoped bookmarks for persistent access; sync existing catalog to newly added volumes with dedup-by-hash
- **Per-File Encryption** — optional AES-256-GCM encryption with PBKDF2 key derivation (600K iterations); pipeline order Hash(raw) → Encrypt → PAR2(ciphertext) → Store enables key-free PAR2 repair and raw-data dedup
- **Deduplication** — exact (SHA-256) and near-duplicate (perceptual hash dHash) detection across all connected volumes; duplicate images are reused across albums without re-processing
- **Storage Reconciliation** — scan all volumes and B2 for discrepancies (dangling references, orphan files, missing entries, hash mismatches) with per-item resolution actions and automatic corruption repair via the Integrity settings tab
- **iCloud Catalog Sync** — catalog.json syncs across devices via iCloud Drive with conflict-free merge (union by SHA-256, newest timestamp wins)
- **Catalog Backup & Restore** — catalog.json is automatically distributed to all external volumes and B2 after every mutation; restore from any backup source (volume, B2, or local file) on fresh run or via Settings
- **Drag & Drop Import** — native file import via `UniformTypeIdentifiers` with image-type filtering
- **Image Format Conversion** — optional JPEG/HEIC conversion with configurable quality and max dimension during import; originals in Photos are never modified
- **Thumbnail Generation** — HEIC/RAW/CR2/CR3/NEF/ARW/DNG support with a multi-resolution cache (256px grid, 64px list) keyed by content hash

## Technology Stack

| Layer           | Framework                                                     |
| --------------- | ------------------------------------------------------------- |
| UI              | SwiftUI (NavigationSplitView, @Observable)                    |
| Data            | SwiftData                                                     |
| Photos Import   | PhotoKit (Photos, PhotosUI)                                   |
| Cloud Sync      | iCloud Drive via NSFileCoordinator                            |
| Cloud Storage   | URLSession + Backblaze B2 REST API                            |
| Image Pipeline  | Core Image, ImageIO                                           |
| Hashing         | CryptoKit (SHA-256, SHA-1)                                    |
| Encryption      | CryptoKit (AES-256-GCM), CommonCrypto (PBKDF2)                |
| In-App Purchase | StoreKit 2                                                    |
| Redundancy      | Standard PAR2 2.0 Reed-Solomon (GF(2^16) Vandermonde matrix)  |
| GPU Compute     | Metal (compute shaders for PAR2 generation)                   |
| Concurrency     | Swift Concurrency (async/await, TaskGroup, actors)            |

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
          │ CatalogService          │  read/write/merge/remove catalog.json
          │ CatalogBackupService    │  distribute catalog to volumes + B2, restore
          │ PhotosImportService     │  PhotoKit album export
          │ ThumbnailService        │  generate + NSCache (128 MB)
          │ DeduplicationService    │  SHA-256 + perceptual hash index
          │ RedundancyService       │  Reed-Solomon ECC encode/verify/repair
          │ B2Service               │  B2 upload/download/list/delete
          │ SyncService             │  iCloud push/pull via NSFileCoordinator
          │ VolumeService           │  disk discovery/bookmarks/sync
          │ ReconciliationService   │  scan volumes + B2 for discrepancies
          │ DeletionService         │  remove files from volumes + B2
          │ IntegrityService        │  verification sweeps
          │ EncryptionService       │  AES-256-GCM encrypt/decrypt, key derivation
          │ PipelinedImportCoord.   │  pipelined async import (AsyncChannel)
          │ ImportCoordinator       │  legacy sequential import
          └────────────┬────────────┘
                       │
          ┌────────────┴────────────┐
          │     Persistence Layer   │
          ├─────────────────────────┤
          │ SwiftData ModelContext  │  local index
          │ catalog.json (Codable)  │  portable JSON catalog
          │ NSFileCoordinator       │  safe concurrent file access
          └─────────────────────────┘
```

## Project Structure

```text
LumiVault/
├── App/                  App entry point, ContentView, SyncCoordinator, menu commands, environment injection
├── Models/               Codable catalog structs, SwiftData models, B2/reconciliation types
├── Services/             Actor-based domain services + coordinators
│   ├── MetalPAR2Service  GPU-accelerated PAR2 via Metal compute shaders
│   └── Persistence/      SwiftData container factory
├── Views/
│   ├── Sidebar/          Year-grouped album list, volume status, context menus (verify, delete)
│   ├── Grid/             LazyVGrid thumbnail browser with context menus (verify, delete)
│   ├── Detail/           Full-resolution preview + metadata inspector
│   ├── Import/           Drag-and-drop file import with progress
│   ├── PhotosImport/     Photos library album picker + import wizard
│   ├── Settings/         General, Volumes, iCloud, B2, Encryption, Import Defaults, Integrity, Support
│   └── Shared/           Reusable components (EmptyStateView)
├── Utilities/            Perceptual hashing, file coordination, bookmarks
└── Resources/            Asset catalog, StoreKit configuration
Tests/                    Unit tests (Swift Testing) + shared TestFixtures
UITests/                  XCUIAutomation UI tests (local development only)
```

## Migration from CLI

LumiVault reads and writes the same `catalog.json` format as the legacy CLI tool. In Settings, use the "Detect Existing" button to locate `~/.lumivault/catalog.json` and import it into the app's local index.

## Testing

125 unit tests across 23 suites covering core logic, using a shared synthetic dataset of 8 deterministic files (512 B to 10 KB) with precomputed SHA-256 hashes. Plus 12 UI tests via XCUIAutomation (Xcode 26) for local development.

```bash
swift test                                    # Run all unit tests
swift test --filter CatalogTests              # Run specific suite

# UI tests (local only — launches the app)
xcodebuild test -project LumiVault.xcodeproj -scheme LumiVaultUITests -destination 'platform=macOS'
```

| Suite | Tests | Coverage |
| --- | --- | --- |
| CatalogTests | 5 | Codable round-trip, optional fields, file I/O, snake_case keys |
| CatalogServiceMergeTests | 5 | Disjoint merge, SHA union, new albums, timestamps, deduplication |
| CatalogRemovalTests | 3 | Album removal, empty container pruning, single image removal |
| HasherServiceTests | 4 | Fixture hash verification, empty file, size tracking, consistency |
| RedundancyServiceTests | 11 | PAR2 2.0 generate/verify, corrupt-and-repair round-trip, split file format, par2cmdline interop (verify + repair), edge cases |
| PerceptualHashTests | 7 | Hamming distance, symmetry, thresholds, invalid input |
| IntegrityServiceTests | 4 | Hash match/mismatch, missing files, batch size |
| SwiftDataModelTests | 5 | Relationships, defaults, Codable support types |
| ReconciliationDiffTests | 5 | B2 diff: matched, dangling, orphan, PAR2 skip, mixed scenario |
| VolumeScanTests | 4 | Dangling location, orphan detection, file exists, unmounted skip |
| VolumeSyncToNewVolumeTests | 5 | Full A-to-B sync, dedup by hash, mismatch, skip, PAR2 companion |
| DeletionServiceTests | 4 | Volume file removal, PAR2 companion, unmounted skip, bulk delete |
| EncryptionServiceTests | 14 | Key derivation, encrypt/decrypt round-trip (data + file), wrong key/AD rejection, nonce uniqueness |
| B2ServiceHelperTests | 7 | SHA-1 known vectors, HTTP response validation (success + error codes) |
| ExportProgressTests | 5 | Fraction calculation: empty, mid-phase, complete, PAR2 sub-progress, single phase |
| CatalogBackupServiceTests | 5 | Volume backup/restore round-trip, error reporting, missing catalog |
| DeduplicationServiceTests | 3 | Unique file detection, exact match, SHA-256 + size verification |
| ImageConversionTests | 5 | JPEG conversion, dimension scaling, below-max preservation, no-op pass-through |
| PerceptualHashComputeTests | 3 | dHash compute returns 8 bytes, deterministic output, non-image rejection |
| VolumeSyncAdditionalTests | 3 | Single-album sync, partial dedup, already-tracked skip |
| EncryptPAR2IntegrationTests | 2 | Encrypt→PAR2→corrupt→repair→decrypt round-trip, uncorrupted verification |
| CatalogBackupRestoreTests | 1 | Volume restore happy path with full fixture verification |
| EncryptionEdgeCaseTests | 4 | Empty data, size = plaintext+16, 1MB large data, file size check |
| **LumiVaultUITests** | **12** | **XCUIAutomation (local only): welcome screen, navigation, settings tabs, import flow, deletion context menu** |

## Requirements

- macOS 26 or later
- Xcode 26 or later (to build from source)
- iCloud account (optional, for catalog sync)
- Backblaze B2 account (optional, for cloud uploads)

## License

This project is licensed under the [MIT License](LICENSE).
