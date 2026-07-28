[![Build](https://github.com/wpowiertowski/lumivault.app/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/wpowiertowski/lumivault.app/actions?query=branch%3Amain)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Swift 6.2](https://img.shields.io/badge/swift-6.2-F05138.svg)](https://swift.org)
[![macOS 26](https://img.shields.io/badge/macOS-26-000000.svg)](https://developer.apple.com/macos/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-blue.svg)](https://developer.apple.com/swiftui/)
[![SwiftData](https://img.shields.io/badge/SwiftData-blue.svg)](https://developer.apple.com/swiftdata/)

<p align="center">
  <img src="icon.png" alt="LumiVault" width="128" height="128">
</p>

# LumiVault

Your photos, preserved forever. Native macOS archiving with Apple Photos integration, Reed-Solomon error correction, and iCloud sync.

---

## Overview

LumiVault is a native macOS 26 application for long-term photo archiving built entirely with Apple frameworks — zero third-party dependencies.

Photos and videos are organized into date-based albums, deduplicated across multiple external volumes, protected with Reed-Solomon error correction, and synced via iCloud. The app reads and writes the same `catalog.json` format as the CLI tool, so both workflows can coexist.

## Features

- **Apple Photos Import** — browse, search, and sort albums from your Photos library; imports both photos and videos, including the current edited state (crops, filters, adjustments) via PhotoKit, and archives in one step; supports multi-album batch import with per-album progress tracking
- **Video Archiving** — import videos alongside photos with an optional "Include videos" toggle; archived exactly as exported by Photos (no transcoding), with poster-frame thumbnails, duration/resolution metadata, and in-app playback via AVKit; large files use the B2 large-file upload API
- **Reed-Solomon Error Correction** — standard PAR2 2.0 format with GF(2^16) Vandermonde-matrix Reed-Solomon coding, fully compatible with par2cmdline and other PAR2 tools; GPU-accelerated via Metal compute shaders (CPU fallback), adaptive block sizing for guaranteed 10% recovery, split file output (.par2 index + .vol0+N.par2 recovery volumes)
- **Integrity Verification & Auto-Repair** — re-hash files against stored SHA-256 digests to detect corruption; auto-repair by copying from a healthy volume or using PAR2 Reed-Solomon recovery; verify and repair individual albums or items via right-click context menus
- **Backblaze B2 Cloud Upload** — upload photos and PAR2 recovery data to B2 cloud storage via the REST API with SHA-1 verification; existence checks prevent duplicate uploads
- **Multi-Volume Mirroring** — mirror albums to multiple external drives with security-scoped bookmarks for persistent access; sync existing catalog to newly added volumes with dedup-by-hash
- **Per-File Encryption** — optional AES-256-GCM encryption with PBKDF2 key derivation (600K iterations); pipeline order Hash(raw) → Encrypt → PAR2(ciphertext) → Store enables key-free PAR2 repair and raw-data dedup
- **Deduplication** — exact (SHA-256) and near-duplicate (perceptual hash dHash) detection across all connected volumes; duplicate images are reused across albums without re-processing
- **Storage Reconciliation** — scan all volumes and B2 for discrepancies (dangling references, orphan files, missing entries, hash mismatches) with per-item resolution actions and automatic corruption repair via the Integrity settings tab
- **iCloud Catalog Sync** — catalog.json syncs across devices via iCloud Drive with conflict-free merge (union by SHA-256, newest timestamp wins)
- **Catalog Backup & Restore** — catalog.json is automatically distributed to all external volumes and B2 after every mutation; restore from any backup source (volume, B2, or local file) on fresh run or via Settings
- **Drag & Drop Import** — native file import via `UniformTypeIdentifiers` with image- and video-type filtering
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
| Video Pipeline  | AVFoundation, AVKit                                           |
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
          │ RedundancyService       │  Reed-Solomon ECC encode/verify/repair
          │ B2Service               │  B2 upload/download/list/delete
          │ SyncService             │  iCloud push/pull via NSFileCoordinator
          │ ReconciliationService   │  scan volumes + B2 for discrepancies, verify, auto-repair
          │ DeletionService         │  remove files from volumes + B2
          │ EncryptionService       │  AES-256-GCM encrypt/decrypt, key derivation
          │ PipelinedImportCoord.   │  pipelined async import (AsyncChannel)
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
│   ├── Settings/         General, Import Defaults, Volumes, iCloud, B2, Encryption, Integrity, Support
│   ├── Games/            Easter-egg Snake / Flappy mini-games shown during long PAR2 phases
│   └── Shared/           Reusable components (EmptyStateView)
├── Utilities/            Perceptual hashing, file coordination, bookmarks
└── Resources/            Asset catalog, StoreKit configuration
Tests/                    Unit tests (Swift Testing) + shared TestFixtures
UITests/                  XCUIAutomation UI tests (local development only)
```

## Migration from CLI

LumiVault reads and writes the same `catalog.json` format as the legacy CLI tool. In Settings, use the "Detect Existing" button to locate `~/.lumivault/catalog.json` and import it into the app's local index.

## Testing

328 unit tests across 60 suites covering core logic, using a shared synthetic dataset of 8 deterministic files (512 B to 10 KB) with precomputed SHA-256 hashes. Plus 12 UI tests via XCUIAutomation (Xcode 26) for local development.

```bash
swift test                                    # Run all unit tests
swift test --filter CatalogTests              # Run specific suite

# UI tests (local only — launches the app)
xcodebuild test -project LumiVault.xcodeproj -scheme LumiVault -destination 'platform=macOS' -only-testing:LumiVaultUITests
```

### Code coverage

The shared scheme gathers coverage, scoped to the `LumiVault` app target so the test
bundles' own lines don't inflate the number:

```bash
# Xcode — writes a result bundle you can open, or query with xccov
xcodebuild test -project LumiVault.xcodeproj -scheme LumiVault \
  -destination 'platform=macOS' -only-testing:LumiVaultTests \
  -enableCodeCoverage YES -resultBundlePath /tmp/cov.xcresult
xcrun xccov view --report /tmp/cov.xcresult

# SwiftPM — same profile data, no app host, runs in seconds
swift test --enable-code-coverage
xcrun llvm-cov report \
  .build/arm64-apple-macosx/debug/LumiVaultPackageTests.xctest/Contents/MacOS/LumiVaultPackageTests \
  -instr-profile .build/arm64-apple-macosx/debug/codecov/default.profdata \
  -ignore-filename-regex='(Tests|\.build)/'
```

The two disagree on purpose. `xcodebuild` launches the app as a test host, so SwiftUI
view code registers as partly covered by the launch itself (and varies between runs);
SwiftPM links the library without a host and reports only what tests actually drive.
Use the SwiftPM number when attributing coverage to tests.

Headline figures: **22.8%** of the app target under SwiftPM. That number is capped at
~36% while views are untested, because SwiftUI view code is 64% of the target and unit
tests do not reach it. The number worth steering by is **non-view coverage: 60.5%**,
which CI gates with a 58% floor via `Scripts/coverage-gate.sh`:

```bash
swift test --enable-code-coverage && ./Scripts/coverage-gate.sh 58
```

Within the non-view code: `EXIFData`, `HasherService`, `PathComponentValidation`,
`AsyncChannel`, `PipelineItem` and `AlbumRecord` at 100%; `MetalPAR2Service` 97%,
`PerceptualHash` 97%, `SettingsSyncService` 86%, `B2Service` 84%,
`ReconciliationService` 79%, `PipelinedImportCoordinator` 73%. The largest remaining
gap is `PhotosImportService` (1.7% of 1,328 lines), which needs the Photos entitlement.

| Suite | Tests | Coverage |
| --- | --- | --- |
| CatalogTests | 4 | Codable round-trip, optional fields, file I/O, snake_case keys |
| CatalogServiceMergeTests | 5 | Disjoint merge, SHA union, new albums, timestamps, deduplication |
| CatalogRemovalTests | 4 | Album removal, empty container pruning, single image removal |
| CatalogMergeSanitizationTests | 3 | Merge drops traversing filenames/album keys, keeps clean entries |
| CatalogVideoSchemaTests | 4 | `media_type`/`duration_seconds` round-trip, legacy decode, commutative reconcile |
| CatalogBackupServiceTests | 5 | Volume backup/restore round-trip, error reporting, missing catalog, orphan vol-file eviction |
| CatalogBackupRestoreTests | 1 | Volume restore happy path with full fixture verification |
| HasherServiceTests | 3 | Fixture hash verification for both hash entry points, empty file, size tracking |
| RedundancyServiceTests | 13 | PAR2 2.0 generate/verify, corrupt-and-repair round-trip, split file format, par2cmdline interop, stale vol-file identification |
| PerceptualHashTests | 5 | Hamming distance at both extremes and a known mid value, invalid input, misaligned buffers |
| PerceptualHashComputeTests | 3 | dHash compute returns 8 bytes, deterministic output, non-image rejection |
| NearDuplicateClusteringTests | 4 | Transitive chains, separate clusters, no-match and singleton cases |
| FilenameDisambiguationTests | 2 | Distinct SHAs never collide on one slot (pinning `name~hash.ext`), no-extension names |
| EXIFDataFormattingTests | 4 | Exposure string formatting incl. sub-second, long exposure, nil and zero |
| SwiftDataModelTests | 5 | Relationships, every persisted default incl. the media fields, Codable support types |
| PhotosSyncSchemaTests | 4 | Lightweight migration for `phAssetLocalIdentifier` / multi-id tracking |
| VideoRecordSchemaTests | 2 | Video field persistence, unknown media type reads as image |
| DeletedRecordGuardTests | 1 | A deleted record detaches and its relationship stays readable |
| ReconciliationDiffTests | 5 | B2 diff: matched, dangling, orphan, PAR2 skip, mixed scenario |
| VolumeScanTests | 4 | Dangling location, orphan detection, file exists, unmounted skip |
| HealReplicasTests | 4 | Restore from a sibling volume, failure reporting, path-traversal refusal, unhealable kinds |
| DeletionServiceTests | 7 | Volume file removal, PAR2 companion, unmounted skip, bulk delete, edge cases |
| SingleImagePAR2DeletionTests | 3 | Single-image delete removes `.vol0+N.par2` too, leaves siblings intact, derives the index name |
| EncryptionServiceTests | 17 | Key derivation, encrypt/decrypt round-trip (data + file), wrong key/AD rejection, nonce uniqueness |
| EncryptionEdgeCaseTests | 4 | Empty data, size = plaintext+16, 1 MB large data, file size check |
| EncryptPAR2IntegrationTests | 2 | Encrypt→PAR2→corrupt→repair→decrypt round-trip, uncorrupted verification |
| B2ServiceHelperTests | 5 | SHA-1 known vectors, HTTP response validation (range upper edge + error codes) |
| B2ServiceNetworkTests | 13 | B2 REST flow via URLProtocol stub: authorize, upload, list pagination, delete, plus retry/backoff and user-facing upload errors |
| B2LargeFileTests | 7 | Large-file API: start/part/finish, cancel, threshold routing, and raw-vs-encoded remote path on both upload routes |
| SyncServiceTests | 20 | push/pull/merge, echo suppression, convergent merge, tombstone propagation and backwards compatibility |
| SettingsSyncServiceTests | 8 | settings.json push/pull, volume-slot merge per host, encryption identity adoption |
| HydrationTests | 12 | Rebuild SwiftData from a catalog: empty store, idempotent upsert, local-only field preservation, staleness (incl. multi-album and skipped entries), deterministic album assignment, tombstones, large catalog |
| CatalogMigrationTests | 6 | Legacy catalog + sidecar migration, never clobbers, and library-as-storage-target resolution |
| CatalogPathResolutionTests | 5 | Catalog path override and tilde expansion without touching process-wide defaults, symlink-resolved library path |
| PathComponentValidationTests | 3 | Rejects traversal and separators in catalog-derived path components |
| URLDescendantTests | 1 | `isDescendant(of:)` truth table |
| AsyncChannelTests | 5 | Bounded async channel: send/receive, backpressure, finish, cancel unblocks producers, multi-producer race |
| AsyncSemaphoreTests | 3 | Counting semaphore: suspension at zero, cancelAll resumes every waiter, wait-after-cancel |
| MemoryBudgetSemaphoreTests | 4 | Byte-budget admission: over-budget waits for a release, oversized solo, queue fairness, cancelAll |
| ChannelCancellationDrainTests | 2 | cancel() does not discard buffered items; a cancelled pipeline stage stops consuming instead of draining the backlog |
| PipelineItemTests | 4 | Converted filename propagates downstream; encrypted/converted/original URL precedence |
| PipelinePhaseRoutingTests | 6 | Stage routing across all 16 phase combinations: never targets a disabled stage, always terminates |
| EnsureFileMirroredTests | 4 | Copy-stage mirroring: skips a matching destination, replaces truncated/empty leftovers |
| ImageConversionTests | 6 | JPEG conversion, dimension scaling, below-max preservation, same-named duplicates stay distinct |
| ImageConversionFormatTests | 3 | HEIC output really is HEIC; alpha stripped from RGBA sources for JPEG and HEIC |
| ThumbnailCacheTests | 4 | Cache root is Application Support (not purgeable Caches), sha-sharded layout, miss reads nil, removal clears both sizes |
| VideoThumbnailTests | 2 | Poster frame + duration/dimension probe from a generated fixture; non-video input throws |
| StallPolicyTests | 6 | iCloud download watchdog: doubling thresholds 1→512s, slow-message suppression, retry countdown |
| ImportProgressBoundsTests | 8 | Progress fraction stays in 0…1 across phases and between albums; expected fractions pinned through the real per-album reset sequence; the `.importing` 10% band and `.complete` reading full; removal phase labelling |
| PhotosLibraryMonitorDiffTests | 9 | Album diff: additions, removals, mixed delta, collapsed duplicates, legacy scalar ids |
| VideoImportSettingsTests | 3 | `includeVideos` resolution from its UserDefaults key, drop-filter accepts movies/images only, duration labels |
| BookmarkResolverTests | 3 | Bookmark round-trip, no rewrite when not stale, corrupt data still throws |
| SnakeGameTests | 7 | Easter-egg Snake state machine: initial state, tick movement, no-direct-reverse, wall collision, food growth, reset |
| FlappyGameTests | 5 | Easter-egg Flappy state machine: hover-before-flap, flap impulse, gravity, floor collision, reset |
| PipelineOrchestrationTests | 12 | The eight-stage import pipeline end to end: persistence, PAR2, encryption, conversion, dedup, copy-failure isolation, cancellation, counter reconciliation, album-deletion rules |
| ReconciliationRepairTests | 9 | Corruption detection via hash verification; repair from a healthy replica and via PAR2; refusal of a mis-hashing source and a traversing path |
| SyncCoordinatorTests | 10 | Catalog distribution to volumes, reload-vs-in-memory push, restore from file, failed restore leaving the catalog intact, disconnected volume skipped |
| EXIFExtractionTests | 7 | Real EXIF/TIFF/GPS parsing incl. hemisphere sign reconstruction, ISO-from-array, DateTimeOriginal fallback, in-memory extraction |
| EXIFFormattingTests | 4 | Aperture/ISO/focal length, megapixels, altitude and coordinate formatting |
| KeychainStoreTests | 4 | Secret round-trip, update-in-place, absent-account delete, account isolation (local only; skipped in CI) |
| **LumiVaultUITests** | **12** | **XCUIAutomation (local only): welcome screen, navigation, settings tabs, import flow, deletion context menu** |

## Requirements

- macOS 26 or later
- Xcode 26 or later (to build from source)
- iCloud account (optional, for catalog sync)
- Backblaze B2 account (optional, for cloud uploads)

## License

This project is licensed under the [MIT License](LICENSE).
