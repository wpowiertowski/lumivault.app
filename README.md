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
- **Deduplication** — exact (SHA-256) and near-duplicate (perceptual hash) detection across all connected volumes
- **Multi-Volume Mirroring** — mirror albums to multiple external drives with security-scoped bookmarks for persistent access
- **Reed-Solomon Error Correction** — PAR2-compatible redundancy implemented natively via Accelerate, interoperable with the CLI tool
- **Scheduled Integrity Verification** — background checks surface corruption via system notifications with one-tap repair
- **Spotlight Integration** — search photos system-wide by album, date, or hash
- **Drag & Drop** — native import/export via `Transferable` and `UniformTypeIdentifiers`

## Technology Stack

| Layer           | Framework                                          |
| --------------- | -------------------------------------------------- |
| UI              | SwiftUI 7 (NavigationSplitView, @Observable)       |
| Data            | SwiftData                                          |
| Photos Import   | PhotoKit (Photos, PhotosUI)                        |
| Cloud Sync      | CloudKit + NSUbiquitousKeyValueStore               |
| Cloud Storage   | URLSession + Backblaze B2 REST API                 |
| Image Pipeline  | Core Image, ImageIO, vImage                        |
| Hashing         | CryptoKit (SHA-256, SHA-1)                         |
| Redundancy      | Accelerate (Reed-Solomon via vDSP)                 |
| Concurrency     | Swift Concurrency (async/await, TaskGroup, actors) |
| Search          | Core Spotlight                                     |

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
          │ ThumbnailService        │  generate, cache, LRU eviction
          │ DeduplicationService    │  SHA-256 + perceptual hash index
          │ RedundancyService       │  Reed-Solomon ECC encode/verify
          │ B2Service               │  Backblaze B2 cloud upload
          │ SyncService             │  iCloud push/pull, conflicts
          │ VolumeService           │  external disk discovery/bookmarks
          │ IntegrityService        │  scheduled verification sweeps
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
├── App/                  App entry point, root state, menu commands
├── Models/               Codable catalog structs, SwiftData models, B2 credentials
├── Services/             Actor-based domain services + export coordinator
│   └── Persistence/      SwiftData container factory
├── Views/
│   ├── Sidebar/          Year/month/day/album tree + volume status
│   ├── Grid/             LazyVGrid thumbnail browser
│   ├── Detail/           Full-resolution preview + metadata inspector
│   ├── Import/           Drag-and-drop import with progress/dedup stats
│   ├── PhotosImport/     Photos library album picker + export wizard
│   └── Settings/         General, Volumes, iCloud, B2 config
└── Utilities/            Perceptual hashing, file coordination, bookmarks
```

## Migration from CLI

LumiVault automatically detects an existing `~/.photovault/catalog.json` on first launch, populates its local index, creates volume bookmarks, and queues thumbnail generation. The app writes catalog.json in the same format, so the CLI tool remains fully functional alongside it.

## Requirements

- macOS 26 or later
- Xcode 26 or later (to build from source)
- iCloud account (optional, for catalog sync)
- Backblaze B2 account (optional, for cloud uploads)

## License

This project is licensed under the [MIT License](LICENSE).
