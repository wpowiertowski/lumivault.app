# LumiVault for macOS — Architecture Document

> Native macOS 26 application reimagining the existing LumiVault CLI as a first-class
> desktop experience built entirely with Apple frameworks.

---

## 1. Goals

| # | Goal | Rationale |
|---|------|-----------|
| G1 | Full catalog.json compatibility | Seamless migration from existing Docker/CLI workflow |
| G2 | iCloud sync of catalog.json | Cross-device catalog access without custom infra |
| G3 | Thumbnail generation & caching | Instant browsing without loading full-resolution originals |
| G4 | Deduplication across multiple external volumes | Prevent wasted space when mirroring to >1 disk |
| G5 | Zero third-party dependencies | Ship with only Apple-provided frameworks |
| G6 | macOS 26 minimum deployment target | Leverage latest platform capabilities |

---

## 2. Technology Stack

| Layer | Framework | Purpose |
|-------|-----------|---------|
| UI | SwiftUI 7 | Declarative interface, NavigationSplitView, @Observable |
| Data | SwiftData | Persistent local index, Spotlight integration |
| Networking / Cloud | NSFileCoordinator + iCloud Drive | iCloud catalog sync |
| Image Pipeline | Core Image, ImageIO | Thumbnail generation, HEIC/RAW decode, perceptual hashing |
| File Access | FileManager, NSURL bookmarks, Security-Scoped Resources | External volume management |
| Hashing | CryptoKit (SHA256) | File integrity, deduplication fingerprints |
| Concurrency | Swift Concurrency (async/await, TaskGroup, actors) | Parallel import, background hashing |
| Redundancy | Custom GF(2^8) Reed-Solomon (Vandermonde matrix) | PAR2-compatible error correction with repair |
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
          │ ThumbnailService        │  ← generate, cache, LRU eviction
          │ DeduplicationService    │  ← SHA-256 + perceptual hash index
          │ RedundancyService       │  ← Reed-Solomon ECC encode/verify/repair
          │ B2Service               │  ← B2 upload/download/list/delete
          │ SyncService             │  ← iCloud push/pull, conflict resolution
          │ VolumeService           │  ← discover, bookmark, mirror, sync
          │ ReconciliationService   │  ← scan volumes + B2 for discrepancies
          │ DeletionService         │  ← remove files from volumes + B2
          │ IntegrityService        │  ← scheduled verification sweeps
          │ EncryptionService       │  ← AES-256-GCM encrypt/decrypt, key derivation
          │ ExportCoordinator       │  ← orchestrates full export pipeline
          └────────────┬────────────┘
                       │
          ┌────────────┴────────────┐
          │     Persistence Layer   │
          ├─────────────────────────┤
          │ SwiftData ModelContext  │  ← local index (ImageRecord, Album, Volume)
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
|--------|--------|
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

**Export pipeline** (per album):

```text
1. User selects album in PhotosAlbumPicker
2. Configure: album name, date, format, PAR2 toggle, encryption, volume targets, B2 toggle
3. ExportCoordinator orchestrates:
   Photos export → staging dir
     → Image format conversion (optional JPEG + resize)
     → SHA-256 hash + dedup check
     → Thumbnail generation
     → Perceptual hash
     → AES-256-GCM encryption (optional)
     → PAR2 generation on ciphertext (optional, GPU-accelerated)
     → Copy to external volumes
     → Upload to B2 (optional)
     → Update SwiftData index + catalog.json
4. Cleanup staging directory
```

Each `PHAsset` is exported via `PHAssetResourceManager.writeData(for:toFile:)` with
`isNetworkAccessAllowed = true` to handle iCloud-originals transparently. The export
prefers the `.fullSizePhoto` resource (edited version with all Photos adjustments) over
the `.photo` resource (unmodified original), while using the original resource's filename
to avoid generic names like `FullSizeRender.jpeg`.

**Album picker** supports search (`.searchable`) and sort (by name, date, or photo count
with ascending/descending toggle).

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
|------|--------|---------|
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

```
VolumeService
  .mirrorAlbum(album, to: [Volume]) → async throws

For each target volume:
  For each image in album:
    if volume already has StorageLocation for this sha256 → skip
    else → copy file + par2, record StorageLocation
```

Each `VolumeRecord` stores a security-scoped bookmark (`NSURL.bookmarkData`) so the app
can re-access external drives across launches without repeated permission prompts.

**Sync existing catalog to new volume**:

When a new volume is added via Settings > Volumes, the app offers to sync all existing
catalog images to the new drive. `VolumeService.syncToVolume()` handles the sync with
dedup-by-hash: if a file already exists at the destination with the correct SHA-256, it
adds a `StorageLocation` without copying. PAR2 companions are copied alongside images.

### 5.6 Storage Reconciliation

**Mechanism**: `ReconciliationService` (actor) scans all mounted volumes and B2 to detect
discrepancies between the database and actual file state.

**Discrepancy types**:

| Kind | Meaning |
| --- | --- |
| `danglingLocation` | DB says file is on volume, but file is missing |
| `orphanOnVolume` | File exists on volume but not tracked in DB |
| `danglingB2FileId` | DB says file is in B2, but B2 listing disagrees |
| `orphanInB2` | File in B2 not referenced by any DB record |
| `missingFromVolume` | File on other volumes but absent from this one |

**Volume scan**: For each image's `storageLocations`, checks `FileManager.fileExists`.
Then enumerates the volume's `year/month/day/album` directory structure to find orphans
not tracked in the database. PAR2 files are excluded from orphan detection.

**B2 scan**: Calls `b2_list_file_names` (paginated) and cross-references against the
database's `b2FileId` values. Pure function `diffB2` is extracted for testability.

**Resolution**: Each discrepancy can be resolved individually (copy from another volume,
download from B2, remove dangling reference, upload to B2, or ignore).

**UI**: Settings > Integrity tab with scan button, progress indicator, and grouped
discrepancy list with per-item resolve actions.

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

**UI**: Context menus on sidebar albums ("Delete Album") and grid photos ("Delete Photo")
with confirmation alerts showing affected item counts. Progress sheet displays phase,
item count, and any errors encountered.

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
│   ├── LumiVaultApp.swift               // @main, WindowGroup, scene config
│   ├── ContentView.swift                // NavigationSplitView root + WelcomeView (restore)
│   └── SyncCoordinator.swift            // App-level sync + catalog backup orchestration
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
│   ├── ExportCoordinator.swift          // Orchestrates full export pipeline
│   ├── DeletionService.swift            // Remove files from volumes + B2
│   ├── ReconciliationService.swift      // Scan volumes + B2 for discrepancies
│   ├── SyncService.swift                // iCloud coordination
│   ├── ThumbnailService.swift           // Generate + cache thumbnails
│   ├── DeduplicationService.swift       // SHA-256 + perceptual hash index
│   ├── RedundancyService.swift          // Reed-Solomon ECC (GF(2^8) Vandermonde)
│   ├── MetalPAR2Service.swift          // GPU-accelerated PAR2 via Metal compute shaders
│   ├── VolumeService.swift              // Disk discovery, bookmarks, sync to volume
│   ├── IntegrityService.swift           // Scheduled verification
│   ├── EncryptionService.swift         // AES-256-GCM encrypt/decrypt, PBKDF2 key derivation
│   └── HasherService.swift              // CryptoKit SHA-256 streaming
│
├── Views/
│   ├── Sidebar/
│   │   ├── SidebarView.swift            // Year-grouped album list + album deletion
│   │   ├── AlbumDeletionSheet.swift     // Deletion progress sheet
│   │   └── VolumeListView.swift         // Connected volumes status
│   ├── Grid/
│   │   ├── PhotoGridView.swift          // LazyVGrid with image deletion
│   │   └── PhotoGridItem.swift          // Single thumbnail cell
│   ├── Detail/
│   │   ├── PhotoDetailView.swift        // Full-resolution preview
│   │   └── MetadataInspector.swift      // EXIF, hash, PAR2, storage locations
│   ├── Import/
│   │   ├── ImportSheet.swift            // Drag-and-drop / folder picker
│   │   └── ImportProgressView.swift     // Per-file progress with dedup stats
│   ├── PhotosImport/
│   │   ├── PhotosAlbumPicker.swift      // Photos library album browser
│   │   ├── ExportSettingsView.swift     // Export configuration form
│   │   └── PhotosExportSheet.swift      // Multi-step export wizard
│   └── Settings/
│       ├── GeneralSettingsView.swift     // Catalog path, redundancy %, restore
│       ├── VolumesSettingsView.swift     // Manage disks + post-add sync
│       ├── VolumeSyncSheet.swift         // Sync existing catalog to new volume
│       ├── ReconciliationView.swift      // Integrity scan + discrepancy resolution
│       ├── CloudSettingsView.swift       // iCloud sync toggle + status
│       ├── B2SettingsView.swift          // Backblaze B2 credentials + test
│       ├── EncryptionSettingsView.swift  // Passphrase management, key status
│       ├── ExportDefaultsSettingsView.swift // Default format, quality, dimensions, PAR2
│       └── SupportSettingsView.swift     // Tip jar via StoreKit 2
│
└── Utilities/
    ├── PerceptualHash.swift             // dHash via Core Image
    ├── Constants.swift                  // Design tokens, paths
    ├── FileCoordination.swift           // NSFileCoordinator helpers
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

Import pipeline uses `TaskGroup` with bounded concurrency:

```swift
func importImages(_ urls: [URL], to album: AlbumRecord) async throws {
    try await withThrowingTaskGroup(of: ImageRecord.self) { group in
        let maxConcurrent = ProcessInfo.processInfo.activeProcessorCount
        // ... bounded parallel hashing + PAR2 + copy
    }
}
```

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

### PAR2-Compatible Reed-Solomon

The macOS app implements Reed-Solomon encoding natively using custom GF(2^8)
arithmetic with Vandermonde matrix coefficients (`(r+1)^b` in GF(2^8)), replacing
`par2cmdline` from the CLI version. The implementation uses a custom `.par2` file
format with header: magic (`PV2R`), fileSize (8B), blockSize (4B), blockCount (4B),
recoveryCount (4B), followed by recovery blocks.

**GPU acceleration**: `MetalPAR2Service` compiles a Metal compute shader at runtime
(from an embedded source string — no Metal Toolchain build dependency) that dispatches
one thread per (byte position × recovery block). A 256×256 GF(2^8) multiplication
table is uploaded to the GPU once at init. Falls back to CPU if Metal is unavailable.

**CPU fallback**: `OperationQueue` with concurrency limited to half of available cores
to avoid system stutter. A shared `OSAllocatedUnfairLock<Bool>` flag enables
cooperative cancellation from the UI.

**Adaptive block size**: Block size scales as a power-of-2 (minimum 4096) to keep
`blockCount × redundancyPercentage ≤ 255` (GF(2^8) field limit), guaranteeing 10%
recovery data for files of any size including 100 MB+ images.

Minimum 2 recovery blocks enables cross-verification to disambiguate which block is
corrupted during repair.

### Integrity Verification

`IntegrityService` re-hashes files against stored SHA-256 digests in configurable
batch sizes. Files are resolved via a caller-provided `sourceResolver` closure,
allowing flexible source selection (volumes, staging directories).

---

## 10. Migration Path from CLI

| Step | Action |
|------|--------|
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
| 4 | ~~Redundancy format~~ | Resolved: Custom PAR2-compatible format with GF(2^8) Vandermonde matrix |
