# LumiVault for macOS — Architecture Document

> Native macOS 26 application reimagining the existing LumiVault CLI as a first-class
> desktop experience built entirely with Apple frameworks.

---

## 1. Goals

| # | Goal | Rationale |
| --- | ------ | ----------- |
| G1 | Full catalog.json compatibility | Seamless migration from existing Docker/CLI workflow |
| G2 | iCloud sync of catalog.json | Cross-device catalog access without custom infra |
| G3 | Thumbnail generation & caching | Instant browsing without loading full-resolution originals |
| G4 | Deduplication across multiple external volumes | Prevent wasted space when mirroring to >1 disk |
| G5 | Zero third-party dependencies | Ship with only Apple-provided frameworks |
| G6 | macOS 26 minimum deployment target | Leverage latest platform capabilities |

---

## 2. Technology Stack

| Layer | Framework | Purpose |
| ------- | ----------- | --------- |
| UI | SwiftUI 7 | Declarative interface, NavigationSplitView, @Observable |
| Data | SwiftData | Persistent local index, Spotlight integration |
| Networking / Cloud | NSFileCoordinator + iCloud Drive | iCloud catalog sync |
| Image Pipeline | Core Image, ImageIO | Thumbnail generation, HEIC/RAW decode, perceptual hashing |
| File Access | FileManager, NSURL bookmarks, Security-Scoped Resources | External volume management |
| Hashing | CryptoKit (SHA256) | File integrity, deduplication fingerprints |
| Concurrency | Swift Concurrency (async/await, TaskGroup, actors, AsyncStream) | Pipelined export, parallel import, background hashing |
| Redundancy | Standard PAR2 2.0 Reed-Solomon (GF(2^16) Vandermonde matrix) | par2cmdline-compatible error correction with repair |
| GPU Compute | Metal | GPU-accelerated PAR2 generation via compute shaders |
| Photos Import | PhotoKit (Photos framework) | Apple Photos album enumeration & asset export |
| Cloud Storage | URLSession | Backblaze B2 REST API uploads |
| Encryption | CryptoKit (AES-256-GCM), CommonCrypto (PBKDF2) | Per-file encryption at rest |
| In-App Purchase | StoreKit 2 | Tip jar consumable products |
| Drag & Drop | UniformTypeIdentifiers, Transferable | Native drag-in import, drag-out export |

---

## 3. High-Level Architecture

```
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
          │ CatalogService          │  ← catalog.json read/write/merge/remove
          │ CatalogBackupService    │  ← distribute catalog to volumes + B2, restore
          │ PhotosImportService     │  ← PhotoKit album export
          │ ThumbnailService        │  ← generate, cache, LRU eviction (shared via Environment)
          │ RedundancyService       │  ← Reed-Solomon ECC encode/verify/repair
          │ B2Service               │  ← B2 upload/download/list/delete
          │ SyncService             │  ← iCloud push/pull, conflict resolution
          │ ReconciliationService   │  ← scan volumes + B2 for discrepancies
          │ DeletionService         │  ← remove files from volumes + B2
          │ EncryptionService       │  ← AES-256-GCM encrypt/decrypt, key derivation
          │ PipelinedImportCoord.   │  ← pipelined import (AsyncChannel between phases)
          └────────────┬────────────┘
                       │
          ┌────────────┴────────────┐
          │     Persistence Layer   │
          ├─────────────────────────┤
          │ SwiftData ModelContext  │  ← local index (LumiVault.store)
          │ catalog.json (Codable)  │  ← portable JSON catalog (existing format)
          │ NSFileCoordinator       │  ← safe concurrent file access
          └─────────────────────────┘
```

---

## 4. Data Model

### 4.1 catalog.json (Existing Format — Preserved)

The app reads and writes the same hierarchical JSON the CLI produces:

```
catalog.json
 └─ version: 1
 └─ last_updated: ISO-8601
 └─ years
     └─ "YYYY"
         └─ months
             └─ "MM"
                 └─ days
                     └─ "DD"
                         └─ albums
                             └─ "Name"
                                 └─ added_at: ISO-8601
                                 └─ images: [ImageEntry]
```

Codable structs mirror this hierarchy exactly. Serialization uses `JSONEncoder` with
`.sortedKeys` and `.iso8601` date strategy for deterministic output.

### 4.2 SwiftData Models (Local Index)

```swift
@Model class ImageRecord {
    @Attribute(.unique) var sha256: String
    var filename: String
    var sizeBytes: Int64
    var par2Filename: String
    var b2FileId: String?
    var addedAt: Date
    var album: AlbumRecord?
    var storageLocations: [StorageLocation]   // volumes where this hash exists
    var thumbnailState: ThumbnailState        // .pending | .generated | .failed
    var perceptualHash: Data?                 // for near-duplicate detection
    var isEncrypted: Bool                     // true if stored as ciphertext
    var encryptionKeyId: String?              // identifies which key encrypted
    var encryptionNonce: Data?                // 12-byte AES-GCM nonce
}

@Model class AlbumRecord {
    var name: String
    var year: String
    var month: String
    var day: String
    var addedAt: Date
    var images: [ImageRecord]
}

@Model class VolumeRecord {
    @Attribute(.unique) var bookmarkData: Data  // security-scoped bookmark
    var label: String
    var mountPoint: String
    var lastSyncedAt: Date?
}
```

`StorageLocation` is a lightweight value tracking `(volumeId, relativePath)` per image
per volume — the core structure enabling multi-volume deduplication.

---

## 5. Feature Design

### 5.1 iCloud Catalog Sync

**Mechanism**: `NSFileCoordinator` + iCloud Drive (Documents container).

Uses the app's iCloud container (hidden from the user in Finder):

```
~/Library/Mobile Documents/iCloud~app~lumivault/catalog.json
```

| Aspect | Design |
| -------- | -------- |
| Write | Atomic write via temp + rename, coordinated with `NSFileCoordinator` |
| Read | `NSMetadataQuery` monitors for remote changes, triggers reload |
| Conflict | Timestamp-based: newest `last_updated` wins at album level; per-image merge by SHA-256 (union) |
| Frequency | On every catalog mutation + on app foreground + on `NSMetadataQuery` notification |
| Fallback | Local catalog in `~/.lumivault/catalog.json` always authoritative if iCloud unavailable |

Conflict resolution strategy (merge, not overwrite):

```
for each year/month/day/album in remote:
    if album missing locally  → adopt remote version
    if album exists locally   → union images by sha256, keep newest added_at
update last_updated = max(local, remote)
```

### 5.1.1 Catalog Backup & Restore

**Mechanism**: `CatalogBackupService` (actor) distributes `catalog.json` to external
volumes and B2, and restores from any backup source. `SyncCoordinator` orchestrates
this automatically after every catalog mutation.

**Backup (automatic)**:

After every local change (export, delete, etc.), `SyncCoordinator.pushAfterLocalChange()`
triggers:

```text
1. Reload catalog from disk
2. Push to iCloud (if enabled)
3. Write catalog.json to root of each mounted external volume
4. Upload catalog.json to B2 (if enabled)
```

Volume bookmarks are resolved from SwiftData via the shared `ModelContainer`.
Errors are logged but do not block the primary operation.

**Restore (user-initiated)**:

Available in two places:

- **WelcomeView** (shown on fresh run with no albums) — "From File...", "From Volume...", "From B2"
- **Settings > General > Restore Catalog** — same options, for existing installations

Restore flow:

```text
1. Load catalog.json from selected source
2. Decode and validate
3. Save to local catalog path
4. Reload into CatalogService
```

### 5.2 Thumbnail Generation & Storage

**Pipeline** (per image):

```
Original file
  → ImageIO CGImageSource (handles HEIC, RAW, CR2, CR3, NEF, ARW, DNG)
  → CGImageSourceCreateThumbnailAtIndex (respects embedded preview)
       options: maxPixelSize = 512, createIfAbsent = true
  → Core Image: auto-orientation via kCGImagePropertyOrientation
  → vImage: lanczos downscale to 256px (grid) + 64px (list)
  → HEIC encode at quality 0.65 via ImageIO destination
  → Write to thumbnail cache
```

**Cache layout**:

```
~/Library/Caches/com.lumivault/thumbnails/
  ├─ 256/
  │   └─ {sha256-prefix-2}/{sha256}.heic
  └─ 64/
      └─ {sha256-prefix-2}/{sha256}.heic
```

- 2-character prefix subdirectories prevent filesystem slowdown on large collections.
- SHA-256 keying means identical images share one thumbnail regardless of filename.
- `NSCache` + in-memory LRU (128 MB cap) for display-ready `CGImage` instances.
- Background `TaskGroup` processes imports in parallel (concurrency = `ProcessInfo.activeProcessorCount`).
- Cache eviction: LRU by access date, triggered when cache exceeds 2 GB.

### 5.3 Apple Photos Import

**Mechanism**: PhotoKit (`Photos` framework) for album enumeration and `PHAssetResourceManager` for original file export.

**Authorization flow**:

1. Check `PHPhotoLibrary.authorizationStatus(for: .readWrite)`
2. If `.notDetermined`, request via `PHPhotoLibrary.requestAuthorization(for:)`
3. If `.denied`, direct user to System Settings > Privacy > Photos

**Album enumeration**:

```text
PHAssetCollection.fetchAssetCollections(with: .album)     → user albums
PHAssetCollection.fetchAssetCollections(with: .smartAlbum) → Favorites, Recents, etc.
```

**Import pipeline** (per album):

```text
1. User selects album(s) in PhotosAlbumPicker
2. Configure: album name, date, format, PAR2 toggle, encryption, volume targets, B2 toggle
3. PipelinedImportCoordinator orchestrates via async pipeline:

   ┌──────────┐   ┌────────────┐   ┌─────────┐   ┌────────────┐   ┌──────┐   ┌──────┐   ┌────────┐   ┌─────────┐
   │  Photos  │──>│ Conversion │──>│ Hashing │──>│ Encryption │──>│ PAR2 │──>│ Copy │──>│ Upload │──>│ Catalog │
   │  Export  │   │ (optional) │   │ & Dedup │   │ (optional) │   │(opt.)│   │(opt.)│   │ (opt.) │   │  Sink   │
   └──────────┘   └────────────┘   └─────────┘   └────────────┘   └──────┘   └──────┘   └────────┘   └─────────┘

   Each phase runs as an independent Task on @MainActor, connected by
   AsyncChannel (bounded async streams with backpressure). Images flow
   through phases independently — image #1 can be in PAR2 while image
   #5 is still hashing. Disabled phases are skipped by wiring channels
   directly to the next active phase.

   Concurrency limits per phase:
     Export: 1 | Conversion: 2 | Hashing: 4 | Encryption: 4
     PAR2: 1 (GPU) | Copy: serial | Upload: serial | Catalog: serial

4. Cleanup staging directory (via defer)
```

**Backpressure**: `AsyncChannel` uses `AsyncSemaphore` (counting semaphore actor) to
block fast producers when slow consumers fall behind. Buffer sizes range from 2 (PAR2)
to 8 (hashing), keeping memory bounded regardless of album size.

**Cancellation**: A sentinel task monitors the parent Task via `withTaskCancellationHandler`.
On cancel, it: (1) sets the `cancelFlag` for PAR2's OperationQueue, (2) cancels all child
tasks, (3) calls `channel.cancel()` on every channel — which resumes blocked semaphore
waiters and terminates all `for await` loops. Empty album records are cleaned up on cancel.

**PipelineItem**: A `Sendable` struct flows through the pipeline, accumulating results
(converted URL, converted filename, SHA-256, encryption nonce, PAR2 filename, etc.).
`activeFilename` resolves the effective filename (converted or original) and `activeFileURL`
resolves the effective file URL (encrypted → converted → original). An `ImageRecordSnapshot`
captures the `PersistentIdentifier` so downstream phases can look up the SwiftData record
without passing non-Sendable `@Model` objects across isolation boundaries.

Each `PHAsset` is exported via `PHAssetResourceManager.requestData(for:options:dataReceivedHandler:completionHandler:)`
with `isNetworkAccessAllowed = true` to handle iCloud-originals transparently, streaming
chunks directly to a `FileHandle`. The export prefers the `.fullSizePhoto` resource
(edited version with all Photos adjustments) over the `.photo` resource (unmodified
original), while using the original resource's filename to avoid generic names like
`FullSizeRender.jpeg`. A per-request watchdog enforces an exponential stall threshold
(1, 2, 4, … up to 512 seconds across 10 attempts): if chunk delivery goes idle past the
current threshold, the request is cancelled via `cancelDataRequest(_:)` and a fresh
request is started. The UI reports retry progress via the `photosDownload` health state.

**Multi-album import**: Users can select multiple albums in the picker. Each album is
imported sequentially through the same pipeline, with per-album settings derived from
the shared configuration (album name and date are overridden per-album from Photos
metadata). Progress tracks both per-album and global file counts.

**Album picker** supports search (`.searchable`) and sort (by name, date, or photo count
with ascending/descending toggle). Asset counts reflect images only (`mediaType == .image`),
matching the import filter — videos and other media types are excluded from counts to
prevent misleading sync status indicators.

**Completion reporting**: The import completion screen shows `filesCataloged` (images
actually added to the album) as the primary count, plus a breakdown of duplicates
skipped and any files that failed to import (`filesDropped`). Items that are silently
dropped in the pipeline (e.g., hash failures producing no snapshot, or SwiftData model
lookup failures in the catalog sink) are tracked and surfaced as errors rather than
silently lost.

### 5.4 Backblaze B2 Cloud Upload

**Mechanism**: `URLSession` + B2 REST API v2. Zero third-party dependencies.

| Endpoint                  | Purpose                                                        |
| ------------------------- | -------------------------------------------------------------- |
| `b2_authorize_account`    | Authenticate with application key, obtain API URL + auth token |
| `b2_get_upload_url`       | Get single-use upload URL for a bucket                         |
| `b2_upload_file`          | Upload file data with SHA-1 verification header                |
| `b2_list_file_names`      | List files in bucket (paginated), check file existence         |
| `b2_download_file_by_id`  | Download file by B2 file ID                                    |
| `b2_delete_file_version`  | Delete a specific file version by ID                           |

**Upload flow** (per file):

```text
1. Authorize (cached across uploads in a session)
2. Check if file already exists via b2_list_file_names (skip if present)
3. Get upload URL (refreshed after each upload — single-use)
4. Upload file with headers:
     X-Bz-File-Name: year/month/day/album/filename
     X-Bz-Content-Sha1: SHA-1 of file data
     Content-Type: b2/x-auto
5. Store returned fileId in ImageRecord.b2FileId
6. Upload corresponding .par2 file (with same existence check)
```

**Deletion flow** (per file):

```text
1. Look up current file version by name via b2_list_file_names (stored fileId may be stale)
2. Call b2_delete_file_version with resolved fileId + fileName
3. Look up PAR2 companion via b2_list_file_names prefix search
4. Delete PAR2 file version if found (best-effort)
```

**Remote path convention**: `{year}/{month}/{day}/{albumName}/{filename}` — mirrors
the local volume layout for consistency.

**Credentials**: Stored locally via `UserDefaults` (application key ID, key, bucket ID,
bucket name). Settings UI includes a "Test Connection" button that calls
`b2_authorize_account` to validate credentials.

### 5.5 Deduplication Across External Volumes

**Two-tier dedup**:

| Tier | Method | Purpose |
| ------ | -------- | --------- |
| Exact | SHA-256 (CryptoKit) | Byte-identical duplicates |
| Near | Perceptual hash (difference hash via Core Image) | Visually similar images (resized, re-encoded) |

**Flow on import**:

```
1. Compute SHA-256 while streaming file
2. Query SwiftData: SELECT * FROM ImageRecord WHERE sha256 = ?
3. If match found:
     → Skip copy, add StorageLocation pointing to existing path
     → Log dedup event (saved N bytes)
4. If no exact match:
     → Compute perceptual hash (dHash, 64-bit)
     → Query: Hamming distance < 5 from any existing perceptualHash
     → If near-match: prompt user — "Similar image found, keep both?"
5. Proceed with PAR2 generation + copy to target volume(s)
```

**Multi-volume mirroring**:

Import writes each output file to every mounted mirror target inline in the
`PipelinedImportCoordinator` store phase. For every image, each volume that already
records a `StorageLocation` for this SHA-256 is skipped; otherwise the file + PAR2
companion are copied and a new `StorageLocation` is appended.

Each `VolumeRecord` stores a security-scoped bookmark (`NSURL.bookmarkData`) so the app
can re-access external drives across launches without repeated permission prompts.

**Sync existing catalog to new volume**:

When a new volume is added via Settings > Volumes, the app offers to sync all existing
catalog images to the new drive. The sync loop lives inline in `VolumeSyncSheet` with
dedup-by-hash: if a file already exists at the destination with the correct SHA-256, it
adds a `StorageLocation` without copying. PAR2 companions are copied alongside images.

### 5.6 Storage Reconciliation & Auto-Repair

**Mechanism**: `ReconciliationService` (actor) scans all mounted volumes and B2 to detect
discrepancies between the database and actual file state, and optionally repairs corrupted
files automatically.

**Discrepancy types**:

| Kind | Meaning |
| --- | --- |
| `danglingLocation` | DB says file is on volume, but file is missing |
| `orphanOnVolume` | File exists on volume but not tracked in DB |
| `danglingB2FileId` | DB says file is in B2, but B2 listing disagrees |
| `orphanInB2` | File in B2 not referenced by any DB record |
| `missingFromVolume` | File on other volumes but absent from this one |
| `hashMismatch` | File exists but SHA-256 differs from expected (corruption) |

**Volume scan**: For each image's `storageLocations`, checks `FileManager.fileExists`.
Then enumerates the volume's `year/month/day/album` directory structure to find orphans
not tracked in the database. PAR2 files are excluded from orphan detection.

**Hash verification**: Optional phase that re-computes SHA-256 for every file on every
volume and compares against the catalog hash, detecting silent corruption (bit rot).

**B2 scan**: Calls `b2_list_file_names` (paginated) and cross-references against the
database's `b2FileId` values. Pure function `diffB2` is extracted for testability.

**Auto-repair**: When enabled, the reconciliation service automatically repairs corrupted
files (`hashMismatch` discrepancies) using a two-step strategy:

```text
1. Copy from healthy volume — for each hash mismatch, check all other volumes for a
   copy with the correct SHA-256. If found, atomically replace the corrupted file.
2. PAR2 repair — if no healthy copy exists on any volume, locate the PAR2 index file
   (.par2) alongside the corrupted file and call RedundancyService.repair() to
   reconstruct corrupted blocks via GF(2^16) Reed-Solomon error correction.
3. If both strategies fail, the file is reported as unrecoverable.
```

Repair results are tracked via `RepairResult` (outcome: `.copiedFromVolume`,
`.repairedViaPAR2`, or `.failed`).

**Resolution**: Each discrepancy can also be resolved individually (copy from another
volume, download from B2, remove dangling reference, upload to B2, or ignore).

**Per-album and per-image verification**: `IntegritySheet` provides a scoped verify +
repair flow accessible via right-click context menus on albums (sidebar) and images
(photo grid). It runs hash verification and auto-repair on just the selected scope.

**UI**: Settings > Integrity tab with scan button, "Verify file hashes" and "Auto-repair"
toggles, progress indicator, and grouped discrepancy list with repair outcome indicators.
Context menus on albums and images offer "Verify & Repair" for targeted checks.

### 5.7 Album & Image Deletion

**Mechanism**: `DeletionService` (actor) orchestrates file removal across all storage
backends in a single operation with progress tracking.

**Deletion flow**:

```text
1. Snapshot image metadata (sha256, storageLocations, b2FileId, par2Filename)
2. Phase 1 — Remove from volumes:
     For each storageLocation on each mounted volume:
       Remove image file + PAR2 companion
       Clean up empty album directory
3. Phase 2 — Remove from B2:
     Delete image file version via b2_delete_file_version
     Look up PAR2 file via b2_list_file_names, delete if found
4. Phase 3 — Update catalog:
     CatalogService.removeAlbum() or .removeImage()
     Prune empty year/month/day containers
     Save catalog.json to disk
5. Phase 4 — Remove from SwiftData:
     modelContext.delete(album) — cascade deletes all images
     Or modelContext.delete(image) for single image
```

**UI**: Context menus on sidebar albums and grid photos include "Verify & Repair" and
"Delete Album" / "Delete Photo" actions. Deletion shows confirmation alerts with affected
item counts and a progress sheet displaying phase, item count, and any errors encountered.

Unmounted volumes are silently skipped — the files remain on disk but the `StorageLocation`
references are removed from the database. A subsequent reconciliation scan will surface
these as orphans if the volume is later mounted.

### 5.8 Per-File Encryption

**Mechanism**: `EncryptionService` (actor) provides AES-256-GCM authenticated encryption
via CryptoKit, with key derivation from a user passphrase via PBKDF2 (CommonCrypto,
600,000 iterations).

**Operation order** (critical for resilience):

```text
Raw file
  → SHA-256(raw)           # identity & dedup on original content
  → Perceptual hash(raw)   # near-duplicate detection on original
  → Thumbnail(raw)         # generate before encryption
  → AES-256-GCM encrypt    # encrypt with unique 12-byte nonce
  → PAR2(ciphertext)       # Reed-Solomon protects encrypted payload
  → Copy/Upload ciphertext # store on volumes and B2
```

**Why this order**:

- PAR2 operates on ciphertext — can repair bit-rot without the encryption key
- SHA-256 is computed on raw data — exact dedup works unchanged
- Thumbnails are generated from raw data — browsable without the key
- Associated data (raw SHA-256) binds ciphertext to file identity via GCM

**Key management**:

- PBKDF2 with SHA-256, 600K iterations, 32-byte random salt (stored in UserDefaults)
- Key ID = first 16 hex chars of SHA-256(derived key) — stored per-file in catalog
- Key cached in memory during session; passphrase never stored
- Settings > Encryption: create/unlock/lock key, change passphrase

**What gets encrypted**:

| Data | Encrypted | Reason |
| ---- | --------- | ------ |
| Image files on volumes/B2 | Yes | Primary protection target |
| PAR2 files | No | Protects ciphertext, reveals no image content |
| Thumbnails (local cache) | No | Low-res, local only, needed for browsing |
| catalog.json | No | Metadata only, keeps CLI compatibility |

**Catalog fields** (backwards-compatible, all optional):

`encryption_algorithm`, `encryption_key_id`, `encryption_nonce` (base64),
`encrypted_size_bytes`. Unencrypted files have `nil` for all fields.

### 5.9 Tip Jar (In-App Purchase)

**Mechanism**: StoreKit 2 with four consumable tip products. The `SupportSettingsView`
loads products via `Product.products(for:)`, handles purchase verification, and displays
a thank-you confirmation. A `TipJar.storekit` configuration file enables local testing
in Xcode without App Store Connect setup.

---

## 6. Module Breakdown

```
LumiVault/
├── App/
│   ├── LumiVaultApp.swift               // @main, WindowGroup, scene config, environment injection
│   ├── ContentView.swift                // NavigationSplitView root + WelcomeView (restore)
│   ├── ImportFromPhotosCommands.swift   // Menu bar command for Photos import
│   └── SyncCoordinator.swift            // App-level sync, catalog backup, catalog mutation
│
├── Models/
│   ├── Catalog.swift                    // Codable structs mirroring catalog.json
│   ├── ImageRecord.swift                // SwiftData @Model + StorageLocation
│   ├── AlbumRecord.swift                // SwiftData @Model (cascade delete → images)
│   ├── VolumeRecord.swift               // SwiftData @Model
│   ├── B2Credentials.swift              // B2 auth, API response, listing types
│   └── ReconciliationTypes.swift        // Sendable snapshots, discrepancies, progress
│
├── Services/
│   ├── Persistence/
│   │   └── SwiftDataContainer.swift     // ModelContainer factory
│   ├── CatalogService.swift             // Load/save/merge/remove catalog.json
│   ├── CatalogBackupService.swift       // Distribute catalog to volumes + B2, restore
│   ├── PhotosImportService.swift        // PhotoKit album enumeration + export
│   ├── B2Service.swift                  // B2 REST API (upload/download/list/delete)
│   ├── PipelinedImportCoordinator.swift  // Pipelined async import
│   ├── PipelineItem.swift               // Sendable item + ImageRecordSnapshot
│   ├── ImageConversionService.swift     // JPEG/HEIC conversion + resize
│   ├── DeletionService.swift            // Remove files from volumes + B2
│   ├── ReconciliationService.swift      // Scan volumes + B2 for discrepancies
│   ├── SyncService.swift                // iCloud coordination
│   ├── ThumbnailService.swift           // Generate + cache thumbnails
│   ├── RedundancyService.swift          // Reed-Solomon ECC (PAR2 2.0, GF(2^16))
│   ├── MetalPAR2Service.swift          // GPU-accelerated PAR2 via Metal compute shaders
│   ├── EncryptionService.swift         // AES-256-GCM encrypt/decrypt, PBKDF2 key derivation
│   └── HasherService.swift              // CryptoKit SHA-256 streaming
│
├── Views/
│   ├── Sidebar/
│   │   ├── SidebarView.swift            // Year-grouped album list (descending) + context menus (verify, delete)
│   │   ├── AlbumDeletionSheet.swift     // Deletion progress sheet
│   │   ├── AlbumExportSheet.swift       // Album export to folder
│   │   └── VolumeListView.swift         // Connected volumes status
│   ├── Grid/
│   │   ├── PhotoGridView.swift          // LazyVGrid with context menus (verify, delete)
│   │   └── PhotoGridItem.swift          // Single thumbnail cell
│   ├── Detail/
│   │   ├── PhotoDetailView.swift        // Full-resolution preview
│   │   └── MetadataInspector.swift      // EXIF, hash, PAR2, storage locations
│   ├── Import/
│   │   ├── ImportSheet.swift            // Drag-and-drop / folder picker
│   │   └── ImportProgressView.swift     // Per-file progress with dedup stats
│   ├── PhotosImport/
│   │   ├── PhotosAlbumPicker.swift      // Photos library album browser
│   │   ├── ImportSettingsView.swift      // Import configuration form
│   │   └── PhotosImportSheet.swift      // Multi-step import wizard
│   ├── NearDuplicatesView.swift  // Near-duplicate pairs browser
│   └── Settings/
│       ├── SettingsView.swift            // Settings tab container
│       ├── GeneralSettingsView.swift     // Catalog path, redundancy %, restore
│       ├── VolumesSettingsView.swift     // Manage disks + post-add sync
│       ├── VolumeSyncSheet.swift         // Sync existing catalog to new volume
│       ├── ReconciliationView.swift      // Integrity scan + auto-repair + discrepancy resolution
│       ├── IntegritySheet.swift          // Per-album / per-image verify & repair sheet
│       ├── B2SyncSheet.swift             // Sync volumes to B2
│       ├── CloudSettingsView.swift       // iCloud sync toggle + status
│       ├── B2SettingsView.swift          // Backblaze B2 credentials + test
│       ├── EncryptionSettingsView.swift  // Passphrase management, key status
│       ├── ImportDefaultsSettingsView.swift  // Default format, quality, dimensions, PAR2
│       └── SupportSettingsView.swift     // Tip jar via StoreKit 2
│
└── Utilities/
    ├── AsyncSemaphore.swift             // Counting semaphore actor (backpressure + cancelAll)
    ├── AsyncChannel.swift               // Bounded async channel with backpressure
    ├── GaloisField16.swift              // GF(2^16) log/antilog tables for PAR2 Reed-Solomon
    ├── PerceptualHash.swift             // dHash via Core Image
    ├── Constants.swift                  // Design tokens, paths
    └── BookmarkResolver.swift           // Security-scoped bookmark utilities
```

---

## 7. Concurrency Model

All services that perform I/O are implemented as Swift actors to guarantee
data-race safety:

```swift
actor CatalogService {
    private var catalog: Catalog

    func load(from url: URL) async throws { ... }
    func save(to url: URL) async throws { ... }
    func merge(remote: Catalog) async -> Catalog { ... }
    func addAlbum(_ result: AlbumResult) async { ... }
}

actor ThumbnailService {
    func thumbnail(for sha256: String, size: ThumbnailSize) async throws -> CGImage
    func warmUp(album: AlbumRecord) async { ... }
}
```

### Import Pipeline Concurrency

The import pipeline uses `AsyncChannel` (bounded `AsyncStream` + `AsyncSemaphore`) to
connect phases. Each phase runs as an unstructured `Task` on `@MainActor` (required for
SwiftData `ModelContext` access). Backpressure prevents fast phases from overwhelming
slow ones — a producer calling `channel.send()` suspends when the buffer is full.

```swift
// Simplified pipeline wiring (from PipelinedImportCoordinator)
let hashingCh = AsyncChannel<PipelineItem>(bufferSize: 8)
let par2Ch = AsyncChannel<PipelineItem>(bufferSize: 2)

let hashTask = Task { @MainActor in
    for await item in hashingCh.stream {
        await hashingCh.consumed()       // free buffer slot
        var result = item
        result.sha256 = try await hasher.sha256AndSize(of: item.fileURL)
        await par2Ch.send(result)         // suspends if PAR2 is behind
    }
    par2Ch.finish()
}
```

Cancellation propagates via a sentinel task that calls `channel.cancel()` on all
channels — this resumes any producers blocked on backpressure (`AsyncSemaphore.cancelAll()`)
and terminates all consumer `for await` loops (`continuation.finish()`).

### Other Concurrent Operations

`TaskGroup` is used for bounded concurrency in non-pipeline contexts (thumbnail warm-up,
integrity verification batches).

---

## 8. iCloud Sync — Sequence Diagram

```
 ┌──────┐      ┌─────────────┐   ┌───────────┐   ┌───────┐  ┌────────┐  ┌────┐
 │ User │      │ CatalogSvc  │   │  SyncCoord│   │ iCloud│  │Volumes │  │ B2 │
 └──┬───┘      └──────┬──────┘   └─────┬─────┘   └───┬───┘  └───┬────┘  └─┬──┘
    │  add album      │               │              │          │         │
    │─────────────────>               │              │          │         │
    │                 │ save to disk  │              │          │         │
    │                 │──────────────>│              │          │         │
    │                 │               │ push iCloud  │          │         │
    │                 │               │─────────────>│          │         │
    │                 │               │ backup vols  │          │         │
    │                 │               │──────────────────────── >│         │
    │                 │               │ backup B2    │          │         │
    │                 │               │───────────────────────────────── >│
    │                 │               │              │          │         │
    │                 │               │ remote change│          │         │
    │                 │               │<─────────────│          │         │
    │                 │ merge(remote) │              │          │         │
    │                 │<──────────────│              │          │         │
    │  UI refresh     │              │              │          │         │
    │<─────────────────              │              │          │         │
```

---

## 9. Storage & Integrity Verification

### Standard PAR2 2.0 Reed-Solomon

The macOS app implements Reed-Solomon encoding natively using GF(2^16) arithmetic
(primitive polynomial x^16 + x^12 + x^3 + x + 1, `0x1100B`) with Vandermonde matrix
coefficients (`pow(base[b], exponent)` in GF(2^16)). Source block bases are computed
as `antilog[logbase]` for logbases coprime to 65535 (= 3 × 5 × 17 × 257), matching
the scheme used by `par2cmdline`. Output uses the standard PAR2 2.0 split file format:

- `.par2` — index file with Main, FileDescription, IFSC (per-block MD5 + CRC32), and Creator packets
- `.vol0+N.par2` — volume file with N RecoverySlice packets plus duplicate metadata

All packet types use the standard 64-byte PAR2 header (magic `PAR2\0PKT`, length,
body MD5, set ID, type). Files generated by LumiVault are fully interoperable with
`par2cmdline` for both verification and repair.

**GPU acceleration**: `MetalPAR2Service` compiles a Metal compute shader at runtime
(from an embedded source string — no Metal Toolchain build dependency) that dispatches
one thread per (UInt16 symbol position × recovery block). GF(2^16) log/antilog tables
(65536 × UInt16 = 128 KB each) are uploaded to the GPU once at init. Falls back to
CPU if Metal is unavailable.

**CPU fallback**: A shared `OSAllocatedUnfairLock<Bool>` flag enables cooperative
cancellation from the UI.

**Adaptive block size**: Block size scales as a power-of-2 (minimum 4096, must be
a multiple of 4 for GF(2^16) UInt16 alignment), guaranteeing 10% recovery data for
files of any size including 100 MB+ images. GF(2^16) supports up to 65535 source
blocks, removing the GF(2^8) field limit of 255.

### Integrity Verification

`ReconciliationService` re-hashes files against stored SHA-256 digests as part of the
discrepancy scan. Hash mismatches are surfaced as `hashMismatch` discrepancies and can
be auto-repaired by copying from a healthy volume or via PAR2 Reed-Solomon recovery.
Per-album/per-image verification runs from the Integrity right-click context menu.

---

## 10. Migration Path from CLI

| Step | Action |
| ------ | -------- |
| 1 | On first launch, detect `~/.lumivault/catalog.json` |
| 2 | Parse with existing Codable structs (same JSON schema) |
| 3 | Populate SwiftData index from catalog entries |
| 4 | Resolve external paths → create VolumeRecord + security-scoped bookmarks |
| 5 | Queue background thumbnail generation for all indexed images |
| 6 | Offer to enable iCloud sync (copies catalog to iCloud container) |

The app continues to write catalog.json in the same format, so the CLI tool
remains fully functional alongside the macOS app.

---

## 11. Non-Goals (v1)

- iOS / iPadOS companion app (catalog is viewable via iCloud, but no native app yet)
- AI-based tagging or face detection
- Photo editing or RAW development
- Video file support
- Perceptual hash near-duplicate threshold tuning (fixed at Hamming distance < 5; adjustable threshold deferred)

---

## 12. Open Questions

| # | Question | Status |
| --- | --- | --- |
| 1 | ~~Should the app also manage B2 uploads natively?~~ | Resolved: Yes, via URLSession + B2 REST API (upload, download, list, delete) |
| 2 | ~~Perceptual hash threshold for "near duplicate"~~ | Deferred: moved to future development; dHash infrastructure remains but threshold tuning is not a v1 priority |
| 3 | ~~iCloud container type~~ | Resolved: App container (hidden) — catalog syncs via the app's iCloud container, not user-visible Documents |
| 4 | ~~Redundancy format~~ | Resolved: Standard PAR2 2.0 format with GF(2^16) Vandermonde matrix, fully interoperable with par2cmdline |
