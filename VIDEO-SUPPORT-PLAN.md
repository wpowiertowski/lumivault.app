# Video File Support — Implementation Plan

> Adds video files (QuickTime/MP4/HEVC etc.) as first-class archive citizens alongside
> images: Photos import, drag-and-drop, dedup, PAR2, encryption, multi-volume mirroring,
> B2 upload, integrity verification, and playback — while keeping catalog.json fully
> backwards-compatible and the zero-third-party-dependency rule (G5) intact.

Companion documents:

- `ARCHITECTURE-macOS.md` §5.10 — the target architecture for video support
- `TEST-PLAN.md` — "Video Support — Planned Test Additions"

---

## 1. Design Principles

1. **Videos are archival originals, not media to re-encode.** No transcoding in v1 —
   the conversion phase passes videos through untouched. LumiVault archives what
   Photos exports.
2. **One record type, one catalog array.** Videos reuse `ImageRecord` and the catalog's
   `images` array with an optional `media_type` discriminator. Renaming the SwiftData
   model or the JSON key would break store migration and the CLI-compatible schema for
   zero benefit.
3. **The pipeline is already 90% format-agnostic.** Hashing, encryption, PAR2, copy,
   upload, deletion, and reconciliation operate on bytes and paths. The work is in the
   endpoints: Photos export, thumbnails, playback, and the places that filter on
   `mediaType == .image`.
4. **Large files are the real feature.** A 4K video is routinely 1–10 GB. Anything that
   currently assumes "file fits comfortably in memory" (encryption, B2 upload) must
   either stream or enforce an explicit, user-visible limit.
5. **Only Apple frameworks.** AVFoundation (poster frames, metadata) and AVKit
   (`VideoPlayer`) — both first-party, no new entitlements needed.

## 2. What Does NOT Change

- SHA-256 hashing (`HasherService`) — already streams, format-agnostic.
- PAR2 generation/verify/repair (`RedundancyService`, `MetalPAR2Service`) — operates on
  bytes; GF(2^16)'s 65,535-block ceiling with power-of-2 block scaling already covers
  multi-GB files (a 10 GB file uses ~256 KB blocks). No format changes.
- Multi-volume copy/mirroring, `StorageLocation` bookkeeping, volume sync.
- Deletion (`DeletionService`) and reconciliation (`ReconciliationService`) — both walk
  records and paths, not image APIs. (Verify during implementation; orphan scan already
  excludes only `.par2`.)
- Catalog merge/tombstone logic — union-by-SHA-256 is media-type-agnostic.
- Encryption *format* — same AES-256-GCM, per-file nonce, same catalog fields.

---

## 3. Implementation Phases

### Phase 1 — Data Model & Catalog Schema (foundation, no behavior change)

**`LumiVault/Models/ImageRecord.swift`**

```swift
enum MediaType: String, Codable, Sendable {
    case image
    case video
}

@Model final class ImageRecord {
    // existing fields …
    var mediaTypeRaw: String = MediaType.image.rawValue   // default ⇒ lightweight migration
    var durationSeconds: Double?                          // videos only
    var pixelWidth: Int?                                  // optional, for inspector
    var pixelHeight: Int?

    var mediaType: MediaType { MediaType(rawValue: mediaTypeRaw) ?? .image }
}
```

Stored raw string with a default value follows the `phAssetLocalIdentifiers` precedent:
existing stores migrate lightweight, legacy records read as `.image`.

**`LumiVault/Models/Catalog.swift`** — `CatalogImage` gains optional fields:

```swift
var mediaType: String?         // "video"; nil/absent = image (legacy)
var durationSeconds: Double?

enum CodingKeys … {
    case mediaType = "media_type"
    case durationSeconds = "duration_seconds"
}
```

Backwards compatibility (hard requirement):

- Old catalogs decode in the new app: both fields optional → `nil` → image. ✔
- New catalogs decode in old app versions: `JSONDecoder` ignores unknown keys, videos
  appear as images in old versions (they render a broken thumbnail but nothing crashes
  or is lost — same degradation class as the tombstone rollout). ✔
- `reconciled(with:)` must pick the new fields commutatively (same `pick` helpers:
  max for `durationSeconds`, lexical-max for `mediaType`), and `normalizedYears()`
  needs no change (fields ride along in `Equatable`).
- `contentEquals` continues to work — new optional fields participate in synthesized
  equality of `CatalogImage`.

**Constants** — `Constants.Media.videoExtensions` / UTType set, plus
`Constants.Media.encryptionSizeLimit` (see Phase 3).

Deliverable: schema + migration tests (see TEST-PLAN), zero UI change.

### Phase 2 — Photos Import

**`ImportTypes.swift`** — `ImportSettings.includeVideos: Bool = true`, mirrored as a
default in Import Defaults settings (`ImportDefaultsSettingsView`).

**`PhotosImportService.swift`** — the five `mediaType == image` predicates become
parameterized:

- `fetchAlbums()` / `medianCreationDate(in:)` / `fetchAssets(in:)` /
  `importedAssetCounts` / the album-fetch in the import path take a
  `Set<PHAssetMediaType>` (or an `includeVideos` flag) so picker counts, median date,
  and sync badges always match exactly what import will ingest. `PhotosAlbum` gains a
  separate `videoCount` so the picker can display "42 photos · 3 videos".
- **Resource selection for videos** mirrors the photo logic:
  `.fullSizeVideo` (edited render) → `.video` (original), with the `.video` resource's
  `originalFilename` used for naming (full-size renders report generic names).
  Live Photo `.pairedVideo` resources are **excluded** — a Live Photo imports as its
  still, exactly as today.
- **Edited video without a materialized render** (edit made on another device;
  adjustment data present but no `.fullSizeVideo` resource) and **slow-mo videos**
  (whose current version is an `AVComposition`, not a file): render via
  `PHImageManager.requestExportSession(forVideo:options:exportPreset:)` with
  `AVAssetExportPresetPassthrough` (falls back to `AVAssetExportPresetHighestQuality`
  when passthrough is incompatible with the composition). Same watchdog/stall pattern
  as `importRenderedAsset` — export sessions report `progress`, which feeds the
  existing `RenderState` idle timer. On failure, fall back to the `.video` original
  (edit lost, media preserved) with the same log-and-continue behavior as photos.
- The existing chunked `PHAssetResourceManager.requestData` export path and its
  exponential stall watchdog are reused unchanged — only the stall thresholds warrant
  review, since a 5 GB iCloud video legitimately downloads for a long time between
  progress callbacks (the watchdog resets per-chunk, so this is likely already fine;
  verify with a real iCloud-offloaded video).

**`PhotosLibraryMonitor.swift`** — album diff must fetch the same media-type set as
import (respecting the user's `includeVideos` default), otherwise sidebar badges will
permanently show phantom pending videos (or miss them).

**`ImportedAsset`** — gains `mediaType` so the pipeline knows what flowed in without
re-sniffing.

### Phase 3 — Pipeline

`PipelineItem` gains `mediaType: MediaType` (Sendable enum, flows through phases).

| Phase | Change |
| --- | --- |
| Export | Phase 2 above. |
| Conversion | **Skip for videos.** `ImageFormat`/quality/max-dimension apply to images only; the conversion phase passes video items straight through (same wiring as a disabled phase, but per-item). |
| Hashing & dedup | Unchanged — exact SHA-256 dedup works for videos as-is. **Perceptual hash is skipped for videos** (`perceptualHash` stays nil; dHash is an image algorithm). Near-duplicate detection is image-only in v1. |
| Thumbnails | New video path in `ThumbnailService` (below), called from the same hashing-phase site. |
| Encryption | Same format. **Size guard**: CryptoKit's one-shot `AES.GCM.seal` holds plaintext + ciphertext in memory (~2× file size). Files above `Constants.Media.encryptionSizeLimit` (default 2 GB) are imported **unencrypted** with a surfaced per-item warning in the completion screen, rather than risking memory exhaustion. Chunked/streaming encryption is future work (§6) because it requires a new on-disk format and new catalog fields. |
| PAR2 | No format change. Multi-GB inputs mean longer GPU dispatches — verify the Metal path chunks its dispatches (or falls back) rather than allocating input × recovery buffers proportional to whole-file size at once; adjust buffer strategy if profiling shows pressure. |
| Copy | Unchanged. |
| Upload | **B2 large-file support** (below). |
| Catalog sink | Writes `media_type`/`duration_seconds` into `CatalogImage`, `mediaTypeRaw`/`durationSeconds`/dimensions into `ImageRecord`. |

**`ThumbnailService`** — one new entry point, same cache layout (SHA-keyed HEIC at
256/64 px, so grid code is untouched):

```swift
func generateVideoThumbnail(for fileURL: URL, sha256: String) async throws {
    let asset = AVURLAsset(url: fileURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true          // rotation
    generator.maximumSize = CGSize(width: 512, height: 512)
    let duration = try await asset.load(.duration)
    let time = CMTime(seconds: min(1.0, duration.seconds / 2), preferredTimescale: 600)
    let (cgImage, _) = try await generator.image(at: time)
    try writeThumbnails(fromPosterFrame: cgImage, sha256: sha256)  // reuses HEIC writer
}
```

Poster frame is grabbed at min(1 s, midpoint) to skip black lead-in frames. Duration
and pixel dimensions are read from the same `AVURLAsset` load and returned to the
pipeline (one probe, not two).

**Encrypted video thumbnails**: pipeline order is unchanged (thumbnail before encrypt),
so import needs nothing special. Cache-miss *regeneration* of an encrypted video's
thumbnail (`PhotoGridItem` fallback path) requires decrypting to a temp file first —
`AVAsset` needs a URL, not `Data`. Decrypt into the sandbox's temp directory with
`FileProtection`, delete in `defer`. This also gates on the 2 GB encryption cap, so the
decrypt-to-temp is bounded.

**`B2Service` — large-file API** (all endpoints already exist in B2 REST v2; still
zero dependencies):

- Threshold: files > 200 MB (B2's recommended cutoff) use
  `b2_start_large_file` → N × (`b2_get_upload_part_url` + `b2_upload_part`) →
  `b2_finish_large_file`, with 100 MB parts, per-part SHA-1, and
  `b2_cancel_large_file` on failure/cancellation. Serial parts in v1 (matches the
  pipeline's serial upload phase).
- Files ≤ 200 MB keep the existing single-call path, but `uploadFileFromDisk` switches
  from `Data(contentsOf:)` + `httpBody` to `URLSession.upload(for:fromFile:)` so even
  the small path stops loading whole files into memory. Parts are read with
  `FileHandle` windows.
- `fileExists` / delete / listing logic is unchanged — large files appear as ordinary
  files in `b2_list_file_names`.
- Progress: part-level callbacks feed the existing `PipelineHealth.b2Upload` state so
  multi-GB uploads don't look wedged.

### Phase 4 — UI

| File | Change |
| --- | --- |
| `ImportSheet.swift` | `panel.allowedContentTypes = [.image, .rawImage, .movie]`; drag-drop filter accepts `UTType.movie`-conforming files; stats line says "items" not "images". |
| `PhotosAlbumPicker.swift` | Show "N photos · M videos" per album; counts driven by the Phase 2 service change. |
| `ImportSettingsView.swift` / `ImportDefaultsSettingsView.swift` | "Include videos" toggle; note that format/quality/max-dimension apply to photos only. |
| `PhotoGridItem.swift` | Video overlay: duration badge (`mm:ss`, monospaced per `Constants.Design`) + play glyph. Thumbnail path identical (SHA-keyed HEIC). Regeneration fallback branches to `generateVideoThumbnail` (with decrypt-to-temp for encrypted). |
| `PhotoDetailView.swift` | Branch on `mediaType`: videos render AVKit `VideoPlayer` (`AVPlayer(url:)` from the resolved volume path). Encrypted videos and B2 previews decrypt/download to a temp file first (cleanup in `onDisappear`/task cancellation). Images keep the current `NSImage` path. |
| `MetadataInspector.swift` | For videos: duration, resolution, codec (from `AVURLAsset` track load) replace the EXIF section; hash/PAR2/storage/encryption/B2 sections unchanged. |
| `NearDuplicatesView.swift` | No change (videos never carry a perceptual hash; candidate query already keys off non-nil hashes — verify). |
| Help book (`photos-import.html`, `drag-drop-import.html`, `import-settings.html`) | Document video support, the no-transcode policy, and the encryption size cap. |

Progress/labels: `PhotosImportProgress.displayLabel` "Processing images" →
"Processing items"; completion screen counts read "items" and surface the
encryption-cap warnings from Phase 3.

### Phase 5 — Verification Pass over Cross-Cutting Services

Audit-and-test (expected no-op, but each gets a test or explicit check):

- `DeletionService` — deletes by path from record; media-type-agnostic. ✔ test with a video fixture.
- `ReconciliationService` — scan by `storageLocations` + directory walk; hash
  verification streams. ✔ include a video fixture in `VolumeScanTests`.
- `CatalogBackupService`, `SyncService`, tombstones — schema-level only. ✔ covered by
  Phase 1 Codable/merge tests.
- `AlbumResyncSheet` / monitor deltas — covered by Phase 2 predicate alignment.

### Phase 6 — Tests, Docs, Project Plumbing

- Automated + manual test additions per `TEST-PLAN.md` ("Video Support — Planned Test
  Additions"): schema round-trip/legacy decode, merge reconciliation, SwiftData
  migration smoke, video poster-frame generation with a bundled fixture `.mov`,
  B2 large-file flow via the existing `URLProtocol` stub, pipeline pass-through of the
  conversion phase for videos.
- Fixture: one tiny (< 1 s, ~100 KB) H.264 `.mov` under `Tests/Fixtures`, generated
  once with AVFoundation and committed (deterministic bytes → stable SHA-256 anchor,
  like the image fixtures).
- `xcodegen generate` + commit the regenerated `.xcodeproj` after any file additions.
- No `Info.plist` / entitlement changes: Photos read access and network client are
  already declared; AVFoundation playback of local files needs no new usage strings.

---

## 4. Suggested PR Sequence

Each lands independently green; order minimizes risk:

1. **PR 1 — Schema**: Phase 1 + its tests. Ships dark (no producer of `media_type`).
2. **PR 2 — B2 large files + streaming upload**: benefits large *images* today; fully
   stub-testable. Ships independent of video.
3. **PR 3 — Pipeline + drag-and-drop import**: MediaType through `PipelineItem`,
   conversion skip, video thumbnails, encryption cap, `ImportSheet` accepts `.movie`.
   First user-visible video feature, exercised without PhotoKit.
4. **PR 4 — Photos import**: predicate parameterization, `.fullSizeVideo` selection,
   export-session render path, monitor alignment, picker counts, settings toggle.
5. **PR 5 — Viewing**: grid badge, `VideoPlayer` detail view, inspector metadata,
   encrypted/B2 temp-file playback, help pages.

## 5. Risks & Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Memory blow-up encrypting multi-GB video (one-shot AES-GCM) | App termination mid-import | Hard size cap with surfaced warning (Phase 3); streaming format as future work |
| B2 single-call upload fails > 5 GB and already buffers whole files in RAM | Failed uploads, memory pressure | Large-file API + `upload(fromFile:)` streaming (Phase 3, PR 2) |
| Slow-mo / cross-device-edited videos aren't file-backed resources | Silently dropped or edit lost | Export-session render path with passthrough→HQ fallback, then original-resource fallback (mirrors photo behavior) |
| Old app versions reading a catalog containing videos | Videos render as broken images on old versions | Accepted degradation; optional-field schema means no decode failure or data loss — same rollout class as tombstones |
| Photos monitor counts drift from import scope | Phantom/missing sidebar badges | Single media-type predicate source shared by picker, monitor, and import (Phase 2) |
| iCloud-offloaded 4K video downloads look stalled | Spurious watchdog cancels | Watchdog resets on every chunk; verify thresholds against a real offloaded video in QA (TC-26) |
| Poster frame at t=0 is black | Ugly grid | Sample at min(1 s, midpoint) with `appliesPreferredTrackTransform` |
| Decrypt-to-temp for playback leaves plaintext on disk | Defeats encryption-at-rest | Sandbox temp dir, file protection, `defer`/`onDisappear` cleanup, bounded by encryption size cap |

## 6. Out of Scope (v1)

- Video transcoding / re-encoding on import (HEVC↔H.264, resizing)
- Streaming/chunked encryption format (required to lift the 2 GB encryption cap)
- Perceptual/near-duplicate detection for videos
- Live Photo paired-video capture (Live Photos continue to import as stills)
- Scrubbing thumbnails / animated grid previews
- Parallel B2 part uploads
