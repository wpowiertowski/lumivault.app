# PhotoVault for macOS — Architecture Document

> Native macOS 26 application reimagining the existing PhotoVault CLI as a first-class
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
| Networking / Cloud | CloudKit + NSUbiquitousKeyValueStore | iCloud catalog sync |
| Image Pipeline | Core Image, ImageIO, vImage | Thumbnail generation, HEIC/RAW decode, perceptual hashing |
| File Access | FileManager, NSURL bookmarks, Security-Scoped Resources | External volume management |
| Hashing | CryptoKit (SHA256) | File integrity, deduplication fingerprints |
| Concurrency | Swift Concurrency (async/await, TaskGroup, actors) | Parallel import, background hashing |
| Redundancy | Accelerate (Reed-Solomon via vDSP) | PAR2-equivalent error correction |
| Spotlight | Core Spotlight | System-wide photo search by album/date/hash |
| Background Work | BackgroundTasks framework | Scheduled verification & thumbnail warm-up |
| Photos Import | PhotoKit (Photos framework) | Apple Photos album enumeration & asset export |
| Cloud Storage | URLSession | Backblaze B2 REST API uploads |
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
          │ CatalogService          │  ← catalog.json read/write/merge
          │ PhotosImportService     │  ← PhotoKit album export
          │ ThumbnailService        │  ← generate, cache, LRU eviction
          │ DeduplicationService    │  ← SHA-256 + perceptual hash index
          │ RedundancyService       │  ← Reed-Solomon ECC encode/verify/repair
          │ B2Service               │  ← Backblaze B2 cloud upload
          │ SyncService             │  ← iCloud push/pull, conflict resolution
          │ VolumeService           │  ← discover, bookmark, mirror external disks
          │ IntegrityService        │  ← scheduled verification sweeps
          │ ExportCoordinator       │  ← orchestrates full export pipeline
          └────────────┬────────────┘
                       │
          ┌────────────┴────────────┐
          │     Persistence Layer   │
          ├─────────────────────────┤
          │ SwiftData ModelContext   │  ← local index (ImageRecord, Album, Volume)
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

```
~/Library/Mobile Documents/iCloud~com~photovault/Documents/catalog.json
```

| Aspect | Design |
|--------|--------|
| Write | Atomic write via temp + rename, coordinated with `NSFileCoordinator` |
| Read | `NSMetadataQuery` monitors for remote changes, triggers reload |
| Conflict | Timestamp-based: newest `last_updated` wins at album level; per-image merge by SHA-256 (union) |
| Frequency | On every catalog mutation + on app foreground + on `NSMetadataQuery` notification |
| Fallback | Local catalog in `~/.photovault/catalog.json` always authoritative if iCloud unavailable |

Conflict resolution strategy (merge, not overwrite):

```
for each year/month/day/album in remote:
    if album missing locally  → adopt remote version
    if album exists locally   → union images by sha256, keep newest added_at
update last_updated = max(local, remote)
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
~/Library/Caches/com.photovault/thumbnails/
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
2. Configure: album name, date, PAR2 toggle, volume targets, B2 toggle
3. ExportCoordinator orchestrates:
   Photos export → staging dir
     → SHA-256 hash + dedup check
     → Thumbnail generation
     → Perceptual hash
     → PAR2 generation (optional)
     → Copy to external volumes
     → Upload to B2 (optional)
     → Update SwiftData index + catalog.json
4. Cleanup staging directory
```

Each `PHAsset` is exported via `PHAssetResourceManager.writeData(for:toFile:)` with
`isNetworkAccessAllowed = true` to handle iCloud-originals transparently.

### 5.4 Backblaze B2 Cloud Upload

**Mechanism**: `URLSession` + B2 REST API v2. Zero third-party dependencies.

| Endpoint               | Purpose                                                        |
| ---------------------- | -------------------------------------------------------------- |
| `b2_authorize_account` | Authenticate with application key, obtain API URL + auth token |
| `b2_get_upload_url`    | Get single-use upload URL for a bucket                         |
| `b2_upload_file`       | Upload file data with SHA-1 verification header                |

**Upload flow** (per file):

```text
1. Authorize (cached across uploads in a session)
2. Get upload URL (refreshed after each upload — single-use)
3. Upload file with headers:
     X-Bz-File-Name: year/month/day/album/filename
     X-Bz-Content-Sha1: SHA-1 of file data
     Content-Type: b2/x-auto
4. Store returned fileId in ImageRecord.b2FileId
5. Upload corresponding .par2 file
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

---

## 6. Module Breakdown

```
PhotoVault/
├── App/
│   ├── PhotoVaultApp.swift              // @main, WindowGroup, scene config
│   └── AppState.swift                   // @Observable root state
│
├── Models/
│   ├── Catalog.swift                    // Codable structs mirroring catalog.json
│   ├── ImageRecord.swift                // SwiftData @Model
│   ├── AlbumRecord.swift                // SwiftData @Model
│   ├── VolumeRecord.swift               // SwiftData @Model
│   └── B2Credentials.swift              // B2 auth + API response types
│
├── Services/
│   ├── Persistence/
│   │   └── SwiftDataContainer.swift     // ModelContainer factory
│   ├── CatalogService.swift             // Load/save/merge catalog.json
│   ├── PhotosImportService.swift        // PhotoKit album enumeration + export
│   ├── B2Service.swift                  // Backblaze B2 REST API uploads
│   ├── ExportCoordinator.swift          // Orchestrates full export pipeline
│   ├── SyncService.swift                // iCloud coordination
│   ├── ThumbnailService.swift           // Generate + cache thumbnails
│   ├── DeduplicationService.swift       // SHA-256 + perceptual hash index
│   ├── RedundancyService.swift          // Reed-Solomon ECC (via Accelerate)
│   ├── VolumeService.swift              // External disk discovery + bookmarks
│   ├── IntegrityService.swift           // Scheduled verification
│   └── HasherService.swift              // CryptoKit SHA-256 streaming
│
├── Views/
│   ├── Sidebar/
│   │   ├── SidebarView.swift            // Year → Month → Day → Album tree
│   │   └── VolumeListView.swift         // Connected volumes status
│   ├── Grid/
│   │   ├── PhotoGridView.swift          // LazyVGrid with async thumbnails
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
│       ├── GeneralSettingsView.swift     // Catalog path, redundancy %
│       ├── VolumesSettingsView.swift     // Manage external disks
│       ├── CloudSettingsView.swift       // iCloud sync toggle + status
│       └── B2SettingsView.swift          // Backblaze B2 credentials + test
│
└── Utilities/
    ├── PerceptualHash.swift             // dHash via Core Image
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
 ┌──────┐          ┌─────────────┐       ┌───────────┐       ┌───────┐
 │ User │          │ CatalogSvc  │       │  SyncSvc  │       │ iCloud│
 └──┬───┘          └──────┬──────┘       └─────┬─────┘       └───┬───┘
    │  add album          │                    │                  │
    │─────────────────────>                    │                  │
    │                     │ save catalog.json  │                  │
    │                     │───────────────────>│                  │
    │                     │                    │ NSFileCoordinator│
    │                     │                    │  write to iCloud │
    │                     │                    │─────────────────>│
    │                     │                    │                  │
    │                     │                    │  remote change   │
    │                     │                    │<─────────────────│
    │                     │                    │ NSMetadataQuery  │
    │                     │  merge(remote)     │                  │
    │                     │<───────────────────│                  │
    │  UI refresh         │                    │                  │
    │<─────────────────────                    │                  │
```

---

## 9. Storage & Integrity Verification

### PAR2-Equivalent with Accelerate

Since `par2cmdline` is a system dependency in the CLI version, the macOS app
implements Reed-Solomon encoding natively using the Accelerate framework's
`vDSP` routines for GF(2^8) arithmetic, matching the existing `.par2` file format
produced by the CLI tool for full interoperability.

### Scheduled Verification

```swift
// BackgroundTasks registration
BGTaskScheduler.shared.register(
    forTaskWithIdentifier: "com.photovault.integrity-check",
    using: nil
) { task in
    // Verify N oldest-unchecked images per run
    // Update lastVerifiedAt on each ImageRecord
    // Surface failures as UserNotification alerts
}
```

- Runs daily when on power, verifying images in LRU order.
- Surfaces corruption via `UserNotification` with one-tap repair action.

---

## 10. Migration Path from CLI

| Step | Action |
|------|--------|
| 1 | On first launch, detect `~/.photovault/catalog.json` |
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

---

## 12. Open Questions

| #   | Question                                              | Status                                                   |
| --- | ----------------------------------------------------- | -------------------------------------------------------- |
| 1   | ~~Should the app also manage B2 uploads natively?~~   | Resolved: Yes, via URLSession + B2 REST API              |
| 2   | Perceptual hash threshold for "near duplicate"        | Hamming distance 5 is conservative; may need tuning      |
| 3   | iCloud container type                                 | Documents (user-visible) vs. app container (hidden)      |
| 4   | Redundancy format                                     | Strict PAR2 interop vs. simplified RS with custom header |
