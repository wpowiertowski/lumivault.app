# LumiVault — QA Test Plan

## Existing Automated Test Assessment

### Summary: 111 tests across 23 suites

| Rating | Suite | Tests | Assessment |
|--------|-------|-------|------------|
| High Value | RedundancyServiceTests | 8 | Core data-integrity logic. Covers encode, verify, corrupt-and-repair round-trips, edge cases. Irreplaceable. |
| High Value | VolumeSyncToNewVolumeTests | 5 | End-to-end copy + hash verification, dedup detection, hash mismatch, PAR2 companion handling. Tests real file I/O. |
| High Value | CatalogServiceMergeTests | 5 | Union-by-SHA merge, timestamp precedence, dedup — exactly the logic that protects multi-device iCloud sync. |
| High Value | CatalogRemovalTests | 3 | Album removal, empty container pruning, single-image removal — validates catalog mutation correctness. |
| High Value | VolumeScanTests | 4 | Reconciliation scan: dangling locations, orphan detection, healthy pass, unmounted skip. Core integrity flow. |
| High Value | DeletionServiceTests | 4 | File removal from volumes, PAR2 companion cleanup, unmounted volume skip, bulk delete. Real FS operations. |
| High Value | ReconciliationDiffTests | 5 | B2 diff logic: matched, dangling B2 IDs, orphans, PAR2 skip, mixed scenarios. Pure logic, well-structured. |
| Medium Value | HasherServiceTests | 4 | Fixture hash verification is the trust anchor for the entire test suite. Empty file + consistency checks are useful but simple. |
| Medium Value | IntegrityServiceTests | 4 | Verify pass/fail/missing and batch-size limit. Solid, but `batchSize` test just checks truncation. |
| Medium Value | CatalogTests | 5 | Codable round-trip, optional fields, snake_case keys, file I/O. Necessary for CLI compatibility guarantee, but scenarios are basic. |
| Low Value | PerceptualHashTests | 7 | All 7 tests exercise a single pure function (`hammingDistance`) with synthetic byte arrays. Zero coverage of actual image hashing (`dHash`). |
| Low Value | SwiftDataModelTests | 5 | Checks defaults and Codable on trivial types. `albumRecordDateLabel` tests string interpolation. These tests will almost never catch a real bug. |

### Redundancy & Overlap

No truly redundant tests. Each test has a distinct scenario. Some suites have tests that are very close (e.g., `deleteRemovesFilesFromVolume` vs `deleteAllFixtureFilesFromVolume` differ only in batch size), but they serve as single-file vs bulk regression guards.

IntegrityServiceTests duplicates fixture materialization inline instead of using `TestFixtures.materializeVolume()` — a maintenance concern, not a test-value issue.

### Critical Gaps in Automated Coverage

| Gap | Risk | Status |
|-----|------|--------|
| EncryptionService | High | **Covered** — 14 tests: key derivation, encrypt/decrypt round-trip, wrong key/AD rejection, nonce uniqueness, file-level operations |
| B2Service (network layer) | High | **Partially covered** — 7 tests on pure helpers (SHA-1, HTTP response validation). Network methods require URLSession abstraction; covered by manual QA. |
| ExportCoordinator (pipeline) | High | **Partially covered** — 5 tests on image conversion (JPEG, scaling, pass-through). Full pipeline orchestration requires service mocking; covered by manual QA. |
| CatalogBackupService | Medium | **Covered** — 5 tests: volume backup/restore round-trip, error reporting, missing catalog handling |
| DeduplicationService | Medium | **Covered** — 3 tests: unique detection, exact match, SHA-256 + size verification |
| ExportProgress | Medium | **Covered** — 5 tests: fraction calculation across phases, PAR2 sub-progress, edge cases |
| SyncService / SyncCoordinator | Medium | Not testable without iCloud provisioning. Catalog merge logic covered by CatalogServiceMergeTests. |
| ThumbnailService | Low | Not tested — visual correctness validated by manual QA. |
| PhotosImportService | Low | Not testable — requires Photos.app sandbox entitlement. Covered by manual QA. |

---

## Manual Test Plan

### Prerequisites

| Item | Details |
|------|---------|
| macOS | 26+ |
| External volumes | 2 USB drives (formatted APFS or ExFAT), labeled distinctly (e.g., "QA-Vol-A", "QA-Vol-B") |
| Apple Photos | Library with at least 2 albums, each containing 5+ photos (mix of HEIC, JPEG, RAW if available) |
| Backblaze B2 | Test bucket with application key (read/write) |
| iCloud | Signed-in Apple ID with iCloud Drive enabled |
| Test images | 10+ images on disk (drag-and-drop import testing), including at least one duplicate pair |

---

### TC-1: First Launch & Welcome Screen

| # | Action | Expected |
|---|--------|----------|
| 1.1 | Launch app with no prior data | Welcome view appears with restore options and arrow pointing to sidebar |
| 1.2 | Click "Detect Existing" | App searches for `~/.lumivault/catalog.json`. If found, shows import summary. If not, shows "not found" message |
| 1.3 | Click "Restore from File" | File picker opens, filtered to `.json` files |
| 1.4 | Select a valid catalog.json | Catalog imports, sidebar populates with year/album tree |
| 1.5 | Select an invalid file (e.g., .txt) | Graceful error, no crash, app remains on welcome screen |

---

### TC-2: Photos Library Import (Happy Path)

| # | Action | Expected |
|---|--------|----------|
| 2.1 | Menu bar > File > Import from Photos | Photos album picker sheet appears |
| 2.2 | Verify album list | Albums from Photos.app displayed with photo counts, sorted alphabetically |
| 2.3 | Use search field | Filters albums by name in real-time |
| 2.4 | Change sort order (name/count/date) | Album list re-sorts correctly |
| 2.5 | Select an album, click "Next" | Export settings screen appears |
| 2.6 | Configure: PAR2 on, JPEG conversion off, near-dupe detection on | Settings reflected in summary |
| 2.7 | Click "Export" | Progress bar appears with phase labels (Exporting, Hashing, PAR2, etc.) |
| 2.8 | Wait for completion | "Complete" screen shows count of exported, deduplicated, skipped images |
| 2.9 | Check sidebar | New album appears under correct year/month/day |
| 2.10 | Click album in sidebar | Photo grid shows all imported thumbnails |

---

### TC-3: Photos Import with JPEG Conversion

| # | Action | Expected |
|---|--------|----------|
| 3.1 | Import an album with JPEG conversion ON, quality 85%, max dimension 2048px | Export completes without error |
| 3.2 | Inspect an exported file on volume | File is JPEG, dimensions <= 2048px on longest edge |
| 3.3 | Verify SHA-256 in metadata inspector | Hash matches the converted JPEG, not the original HEIC |

---

### TC-4: Export Cancellation

| # | Action | Expected |
|---|--------|----------|
| 4.1 | Start a large album export (20+ photos) | Progress begins |
| 4.2 | Click "Cancel" during export | Export stops within 2-3 seconds |
| 4.3 | Check sidebar | No partial/corrupt album entry created |
| 4.4 | Check volumes | No partial files left on disk |

---

### TC-5: Drag & Drop Import

| # | Action | Expected |
|---|--------|----------|
| 5.1 | Drag 5 image files from Finder onto the app window | Import sheet appears with file list |
| 5.2 | Drag a folder containing images | All images inside the folder are listed |
| 5.3 | Drag a non-image file (.pdf, .txt) | File is filtered out; only images shown |
| 5.4 | Complete the import | Images appear in new album, thumbnails load |

---

### TC-6: Deduplication — Exact (SHA-256)

| # | Action | Expected |
|---|--------|----------|
| 6.1 | Import the same album twice | Second import reports all images as "deduplicated", 0 new copies |
| 6.2 | Check catalog.json | No duplicate SHA-256 entries in the album |
| 6.3 | Check volume | No duplicate files on disk |

---

### TC-7: Deduplication — Near-Duplicate (Perceptual Hash)

| # | Action | Expected |
|---|--------|----------|
| 7.1 | Import photos that include slight crops/edits of the same image | Near-duplicate warning appears during export (if detection enabled) |
| 7.2 | Open Library > Near Duplicates view | Duplicate pairs listed with similarity percentage |
| 7.3 | Verify Hamming distance threshold | Only pairs within threshold (default <5) are flagged |

---

### TC-8: Multi-Volume Mirroring

| # | Action | Expected |
|---|--------|----------|
| 8.1 | Settings > Volumes > Add Volume > select QA-Vol-A | Volume appears in list with label and ID |
| 8.2 | Export an album targeting QA-Vol-A | Files appear on QA-Vol-A under `year/month/day/albumName/` hierarchy |
| 8.3 | Add QA-Vol-B via Settings > Volumes | Second volume appears |
| 8.4 | Settings > Volumes > Sync to QA-Vol-B | Progress shown; files copied from QA-Vol-A to QA-Vol-B |
| 8.5 | Verify files on QA-Vol-B | Same directory structure, same file hashes as QA-Vol-A |
| 8.6 | Check image metadata inspector | StorageLocations shows entries for both vol-A and vol-B |
| 8.7 | Eject QA-Vol-A, then sync to QA-Vol-B again | Reports "deduplicated" for all files (already on target) |

---

### TC-9: Volume Removal

| # | Action | Expected |
|---|--------|----------|
| 9.1 | Settings > Volumes > Remove QA-Vol-B | Confirmation dialog appears |
| 9.2 | Confirm removal | Volume disappears from list |
| 9.3 | Check image storage locations | QA-Vol-B entries removed from all images |
| 9.4 | Files on QA-Vol-B | Remain on disk (removal only clears bookmarks/tracking, not files) |

---

### TC-10: PAR2 Error Correction

| # | Action | Expected |
|---|--------|----------|
| 10.1 | Export an album with PAR2 enabled | `.par2` companion files created alongside each image |
| 10.2 | Right-click image > Verify Integrity | "Passed" result, green checkmark |
| 10.3 | Hex-edit an image file on the volume (corrupt ~5% of bytes) | — |
| 10.4 | Verify Integrity on the corrupted file | "Failed" — hash mismatch detected |
| 10.5 | Right-click > Repair | File repaired using PAR2 data; re-verify shows "Passed" |
| 10.6 | Compare repaired file hash to original | SHA-256 matches the original pre-corruption hash |

---

### TC-11: Encryption

| # | Action | Expected |
|---|--------|----------|
| 11.1 | Settings > Encryption > Set passphrase "test1234" | Passphrase saved, encryption enabled |
| 11.2 | Export an album with encryption ON | Files on volume are encrypted (not viewable in Finder preview) |
| 11.3 | Select encrypted image in grid | Thumbnail loads (decrypted in-memory for display) |
| 11.4 | Open detail view | Full-resolution decrypted preview shown |
| 11.5 | Metadata inspector | Shows "Encrypted: Yes", encryption nonce present |
| 11.6 | Change passphrase to "newpass" | — |
| 11.7 | Verify old encrypted files still decrypt | App should use stored per-file key derivation, NOT require the current passphrase to match |
| 11.8 | Export new album with new passphrase | New files encrypted with new key |

---

### TC-12: Backblaze B2 Cloud Upload

| # | Action | Expected |
|---|--------|----------|
| 12.1 | Settings > B2 > Enter application key ID, application key, bucket name | Credentials saved |
| 12.2 | Click "Test Connection" | Success message with bucket info |
| 12.3 | Export album with B2 upload enabled | Upload progress shown per-file; SHA-1 verification on upload |
| 12.4 | Check B2 bucket (via web console) | Files present at `year/month/day/albumName/filename` paths |
| 12.5 | Upload same album again | All files reported as "already exists" — no re-upload |
| 12.6 | Check `b2FileId` in metadata inspector | Populated for each uploaded image |

---

### TC-13: B2 Upload with PAR2

| # | Action | Expected |
|---|--------|----------|
| 13.1 | Export album with both PAR2 and B2 enabled | Both image and `.par2` files uploaded to B2 |
| 13.2 | Verify in B2 console | PAR2 files present alongside images |

---

### TC-14: iCloud Catalog Sync

| # | Action | Expected |
|---|--------|----------|
| 14.1 | Settings > iCloud > Enable sync | Sync status indicator appears |
| 14.2 | Export an album on Device A | Catalog updates locally and pushes to iCloud |
| 14.3 | Open LumiVault on Device B (same iCloud account) | Catalog pulls from iCloud; new album visible in sidebar |
| 14.4 | Export a different album on Device B | — |
| 14.5 | Return to Device A, trigger sync | Device B's album now visible; union merge preserves both |
| 14.6 | Simulate conflict: edit album on both devices while offline, then reconnect | Merge uses union-by-SHA + newest-timestamp-wins; no data loss |

---

### TC-15: Catalog Backup & Restore

| # | Action | Expected |
|---|--------|----------|
| 15.1 | After exporting to volumes and B2, check each volume root | `catalog.json` present on each mounted volume |
| 15.2 | Check B2 bucket | `catalog.json` uploaded |
| 15.3 | Delete local app data (reset SwiftData container) | — |
| 15.4 | Relaunch app | Welcome screen appears |
| 15.5 | Restore from volume > select catalog.json on QA-Vol-A | Full catalog restored, sidebar repopulated |
| 15.6 | Repeat from B2: Settings > Restore from B2 | Catalog downloaded and restored from cloud |

---

### TC-16: Album Deletion

| # | Action | Expected |
|---|--------|----------|
| 16.1 | Right-click album in sidebar > Delete | Confirmation dialog with count of images and affected locations |
| 16.2 | Confirm deletion | Progress indicator shows phases: volumes, B2, catalog |
| 16.3 | Check sidebar | Album removed from tree |
| 16.4 | Check volumes | Image files and PAR2 companions deleted |
| 16.5 | Check B2 | Files deleted from bucket |
| 16.6 | Check empty parent directories | Cleaned up if album was the only occupant |

---

### TC-17: Single Image Deletion

| # | Action | Expected |
|---|--------|----------|
| 17.1 | Select image in grid > Delete (toolbar or context menu) | Confirmation dialog |
| 17.2 | Confirm | Image removed from grid, files deleted from volumes and B2 |
| 17.3 | Remaining images in album | Unaffected, counts updated |
| 17.4 | If last image in album | Album should remain (empty) or be pruned — verify behavior matches design intent |

---

### TC-18: Storage Reconciliation

| # | Action | Expected |
|---|--------|----------|
| 18.1 | Settings > Integrity > Run Reconciliation | Scan begins with progress (Scanning Volumes, Scanning B2, Resolving) |
| 18.2 | With all volumes mounted and B2 healthy | "No discrepancies found" |
| 18.3 | Manually delete a file from QA-Vol-A, then re-run | Dangling location detected for that file |
| 18.4 | Manually place an extra file on QA-Vol-A, then re-run | Orphan on volume detected |
| 18.5 | Review discrepancy list | Each item shows SHA, filename, kind, and available resolution actions |
| 18.6 | Resolve dangling location > "Copy from Volume B" | File copied from QA-Vol-B to QA-Vol-A |
| 18.7 | Resolve orphan > "Ignore" or "Delete" | Orphan dismissed or removed |

---

### TC-19: Integrity Verification

| # | Action | Expected |
|---|--------|----------|
| 19.1 | Select image > Metadata Inspector > Verify Integrity | Re-hashes file, shows pass/fail with actual vs stored hash |
| 19.2 | Bulk verify (Settings > Integrity > Verify All) | Batch progress, summary of pass/fail counts |
| 19.3 | Corrupt a file on disk, then verify | Mismatch detected, repair option offered |

---

### TC-20: Thumbnail Behavior

| # | Action | Expected |
|---|--------|----------|
| 20.1 | Import album with HEIC images | Grid thumbnails render within 2 seconds |
| 20.2 | Import RAW images (CR2/CR3/NEF/ARW/DNG) | Thumbnails render correctly (may be slower) |
| 20.3 | Scroll rapidly through 100+ image grid | No blank thumbnails, no memory spike, smooth scrolling |
| 20.4 | Quit and relaunch | Cached thumbnails load instantly (no regeneration) |
| 20.5 | Switch between grid (256px) and list (64px) views | Correct resolution used for each mode |

---

### TC-21: Navigation & UI

| # | Action | Expected |
|---|--------|----------|
| 21.1 | Sidebar year groups | Expandable/collapsible, shows album count |
| 21.2 | Click album | Grid view loads with thumbnails |
| 21.3 | Click image in grid | Detail view shows full-resolution preview |
| 21.4 | Metadata inspector | Shows: filename, SHA-256, size, storage locations, B2 status, encryption status, PAR2 status, last verified date |
| 21.5 | Window resize | All views adapt correctly, no layout clipping |
| 21.6 | Multiple albums selected rapidly | Grid updates without stale data from previous album |
| 21.7 | Empty album selected | Empty state view shown with appropriate message |

---

### TC-22: Settings Tabs

| # | Action | Expected |
|---|--------|----------|
| 22.1 | General tab | App preferences displayed and editable |
| 22.2 | Export Defaults tab | Format, quality, max dimension, PAR2 toggle, near-dupe toggle — all persist after closing settings |
| 22.3 | Volumes tab | Lists registered volumes with mount status |
| 22.4 | iCloud tab | Sync toggle, last sync timestamp |
| 22.5 | B2 tab | Credential fields, test connection button, setup guide link |
| 22.6 | Encryption tab | Passphrase field, enable/disable toggle |
| 22.7 | Integrity tab | Reconciliation and verification buttons |
| 22.8 | Support tab | Tip jar with 4 tiers, purchase flow via StoreKit 2 |

---

### TC-23: Edge Cases & Error Handling

| # | Action | Expected |
|---|--------|----------|
| 23.1 | Export to a full disk (no space) | Graceful error with message, no partial corruption |
| 23.2 | Eject volume during export | Export fails with error, no crash, partial files cleaned up |
| 23.3 | Invalid B2 credentials | "Test Connection" shows clear error message |
| 23.4 | Network disconnection during B2 upload | Upload fails gracefully, retry possible |
| 23.5 | Import album with 0 photos | Empty album created or rejected — document behavior |
| 23.6 | Photo with no EXIF data | Imports successfully with default/empty metadata |
| 23.7 | Filename with special characters (spaces, accents, emoji) | Handled correctly across export, volume copy, B2 upload |
| 23.8 | Very large image (>50MB RAW) | Exports without timeout or memory crash |
| 23.9 | Photos library permission denied | App shows permission prompt, Settings link to System Preferences |

---

### TC-24: Tip Jar (StoreKit 2)

| # | Action | Expected |
|---|--------|----------|
| 24.1 | Settings > Support | 4 tip tiers displayed with prices |
| 24.2 | Tap a tip tier | StoreKit purchase sheet appears |
| 24.3 | Complete purchase (sandbox) | Thank-you confirmation shown |
| 24.4 | Cancel purchase | No error, returns to tip jar |

---

### TC-25: Security-Scoped Bookmarks

| # | Action | Expected |
|---|--------|----------|
| 25.1 | Add volume, quit app, relaunch | Volume still accessible (bookmark persisted) |
| 25.2 | Rename external volume in Finder | Bookmark resolves to new name; access works or stale bookmark detected |
| 25.3 | Eject and re-insert volume | Access restored via bookmark without re-adding |

---

## Priority Matrix

### P0 — Must Pass (data loss risk)

- TC-2: Photos Import
- TC-6: SHA-256 Dedup
- TC-8: Multi-Volume Sync
- TC-10: PAR2 Error Correction
- TC-11: Encryption
- TC-15: Catalog Backup & Restore
- TC-16: Album Deletion
- TC-18: Reconciliation
- TC-23.1-23.2: Disk full / eject during export

### P1 — Should Pass (functionality risk)

- TC-3: JPEG Conversion
- TC-4: Export Cancellation
- TC-5: Drag & Drop
- TC-12: B2 Upload
- TC-14: iCloud Sync
- TC-17: Single Image Deletion
- TC-19: Integrity Verification
- TC-25: Bookmarks

### P2 — Nice to Verify (UX/polish)

- TC-1: Welcome Screen
- TC-7: Near-Duplicate
- TC-13: B2 PAR2
- TC-20: Thumbnails
- TC-21: Navigation UI
- TC-22: Settings
- TC-24: Tip Jar
- TC-23.5-23.9: Edge cases
