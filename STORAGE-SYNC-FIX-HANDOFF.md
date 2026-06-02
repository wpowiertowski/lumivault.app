# Storage Sync Bug — Debug & Fix Handoff

**Branch:** `claude/lumivault-storage-sync-bug-Wthas`
**PR:** https://github.com/wpowiertowski/lumivault.app/pull/41
**Status:** Implemented & pushed. Not yet compiled/tested locally (macOS-only target; built in a Linux sandbox, reviewed by hand).

---

## 1. The Bug (reported symptoms)

- Deleted an album, re-uploaded it; **one image saved its HEIC + PAR2 to Backblaze B2 but not to the external drives**.
- The image showed a **missing preview** locally, but was loadable from B2.
- **Verification reported the file as missing** from a volume.
- Removing the image and re-syncing with Apple Photos **repeated the same outcome** (B2 only, not drives).
- Additional observations:
  - The file was *originally* copied to drives, but a re-sync flagged it missing and tried to add a **second copy**, which **skipped the drive write but uploaded to B2**.
  - When **removing a single image, the support files (PAR2) were not removed**.

---

## 2. Root Cause

### Primary: copy stage blindly trusts pre-existing files
`PipelinedImportCoordinator.runCopyStage` mirrored files to volumes with:

```swift
let dest = destBase.appendingPathComponent(snap.filename)
if !FileManager.default.fileExists(atPath: dest.path) {
    try FileManager.default.copyItem(at: sourceFile, to: dest)
}
// StorageLocation appended REGARDLESS of whether a write happened
```

If *any* file already sat at the destination (stale/partial leftover, or a filename
collision from a re-synced "second copy"), the real bytes were **never written**, yet the
`StorageLocation` was recorded as valid and **no error was raised**. The independent B2
upload stage then ran and succeeded → **B2 has it, drive doesn't, record claims both**.
Verification (`ReconciliationService.scanVolumes`) later does its own `fileExists` on the
recorded path, finds nothing, and emits `.danglingLocation`.

### Pipeline ordering / coupling
Stages run `… → PAR2 → Copy → Upload → Catalog`. Copy and Upload were chained through a
single `item.error`:
- A copy failure set `item.error`, which **skipped the B2 upload** (a flaky drive blocked B2).
- The silent `fileExists` skip left no error, so upload proceeded while the drive stayed empty.

The two storage targets were **not independent**.

### Why it persisted across re-syncs (the leftover loop)
Single-image deletion (`DeletionService`, `entireAlbum: false`) only removed PAR2 companions
`if !image.par2Filename.isEmpty`. A re-synced **"second copy"** record has an **empty
`par2Filename`** (the PAR2 pipeline stage skips deduplicated images). So
`<filename>.par2` / `<filename>.vol*.par2` were **orphaned on the drive**, and those
leftovers kept triggering the `fileExists` short-circuit on the next import.

### Note on "sha2" files
There are **no per-image `.sha256` sidecars**. The only `.sha256` is `catalog.json.sha256`
at the volume root (catalog integrity, written by `CatalogBackupService`) — correct to leave
in place. The "support files not removed" issue was the PAR2 companions.

---

## 3. Changes Made

All on branch `claude/lumivault-storage-sync-bug-Wthas` (9 files, commit `9583db8`).

### Pipeline — `LumiVault/Services/PipelinedImportCoordinator.swift`, `PipelineItem.swift`
- **New `ensureFileMirrored(from:to:)`** static helper: if a destination exists, compares its
  size to the source; if mismatched/partial/zero-byte it removes and re-copies. Replaces the
  blind `if !fileExists { copy }` for **both the image and PAR2 companions**. Throws on real
  failure so the caller records a genuine per-volume error (no phantom success).
- **Decoupled copy from upload:** added `PipelineItem.copyError` (separate from `error`). Copy
  failures now record `copyError` + `progress.errors` and **no longer block the B2 upload**.
  `error` remains reserved for upstream stage-blocking failures (hash/encrypt/PAR2).

### Deletion — `LumiVault/Services/DeletionService.swift`
- Single-image deletion (volume + B2 paths) now derives the PAR2 index name from the image
  **filename** when `par2Filename` is empty:
  `let par2Index = image.par2Filename.isEmpty ? image.filename + ".par2" : image.par2Filename`
  so `<filename>.par2` / `.vol*.par2` are removed even for "second copy" records.

### Verification auto-heal (opt-in) — `ReconciliationService.swift`, `ReconciliationTypes.swift`
- **`ReconciliationService.healReplicas(discrepancies:snapshots:volumes:b2Credentials:progress:)`**
  handles `.danglingLocation` and `.danglingB2FileId`:
  - **Missing from a volume** → restore from a healthy sibling volume (hash-verified when
    unencrypted) **or download from B2**, plus PAR2 companions.
  - **Missing from B2** → re-upload from a healthy local replica, plus PAR2 companions; returns
    the new `fileId` via `.restoredToB2(newFileId:)` for write-back.
  - Encryption-aware: ciphertext replicas are trusted intact (can't hash-check ciphertext vs.
    plaintext SHA); B2 stored bytes mirror the on-volume representation so they're written as-is.
- New `HealResult` type and `.healing` reconciliation phase.
- `ImageSnapshot` gained `isEncrypted: Bool` with a **`nonisolated init` defaulting it to false**
  (keeps all existing call sites / tests source-compatible).

### Catalog write-back — `CatalogService.swift`, `App/SyncCoordinator.swift`
- `CatalogService.updateImageB2FileId(sha256:b2FileId:)` updates an existing image's `b2FileId`
  in the catalog tree (re-upload yields a fresh fileId).
- `SyncCoordinator.updateImageB2FileId(...)` wrapper that updates + saves `catalog.json`.

### UI — `Views/Settings/ReconciliationView.swift`, `Views/Settings/IntegritySheet.swift`
- **ReconciliationView (Settings → integrity scan):** new **"Heal missing replicas"** opt-in
  toggle. After the scan (+ optional auto-repair) it runs `healReplicas`, applies B2 fileId
  write-backs (SwiftData + catalog.json), then re-scans to reflect the restored state. New
  `HealResultRow` + "Restored Replicas" section.
- **IntegritySheet (per-album / per-image verify, from Sidebar + PhotoGrid):** new opt-in
  **"Restore Missing Replicas"** button shown when there are healable issues. It keeps its
  reconcile scan **volume-only** (`b2Credentials: nil`) to avoid subset orphan-in-B2 false
  positives, but passes real B2 credentials to `healReplicas` so B2 can be a restore **source**.

---

## 4. Verification Still Pending (do this in the next session)

```bash
# macOS, with Xcode toolchain:
swift build
swift test
# or
xcodegen generate && xcodebuild -project LumiVault.xcodeproj -scheme LumiVault -configuration Debug build
```

Manual sanity check of the actual bug:
1. Configure ≥1 external volume + B2.
2. Import an album, then delete it (album + single-image paths).
3. Re-import / re-sync; confirm the HEIC **and** PAR2 land on both drive(s) and B2.
4. In Settings → integrity, run a scan with **Heal missing replicas** on; confirm a file
   present only on B2 is restored to the drive (and vice-versa).
5. Delete a single image; confirm its `.par2` / `.vol*.par2` are gone from drive and B2.

---

## 5. Known Follow-ups / Open Decisions

- **PAR2 not generated inline for duplicate re-syncs.** The PAR2 pipeline stage skips
  deduplicated images, so a "second copy" import doesn't *generate* PAR2 — the heal pass
  restores PAR2 redundancy after the fact. Optional follow-up: regenerate/copy PAR2 for
  duplicates during import. (Not done; flagged.)
- **Deeper "second copy" question:** why does a re-sync sometimes treat an already-imported
  photo as new/missing (dedup miss)? Not investigated — the current fixes make the *outcome*
  safe (no phantom drive locations, companions cleaned, heal restores), but the resync diff
  logic in `PhotosImportService` could be a separate hardening target.
- **CI / PR:** PR #41 is open. Not yet watching CI or reviews.

---

## 6. Key Files / Line Anchors (pre-existing behavior reference)

- Import pipeline topology & stage gating: `PipelinedImportCoordinator.swift`
  - copy stage `runCopyStage` (~line 990+), upload stage `runUploadStage` (~1100+),
    hash/dedup `runHashStage` (~700+), catalog sink (~377+).
- Reconciliation existence scan: `ReconciliationService.scanVolumes` (emits `.danglingLocation`).
- Existing repair (hash mismatch only): `ReconciliationService.repairCorruptedFiles`.
- B2 download/upload/list: `B2Service.swift` (`downloadFile(fileId:)`, `uploadImage`,
  `listAllFiles`, `fileExists`).
- PAR2 companion naming: `RedundancyService.companionFiles(forIndex:in:)`.
- Models: `ImageRecord.swift` (`storageLocations`, `b2FileId`, `par2Filename`, `isEncrypted`),
  `Catalog.swift` (`CatalogImage`), `ReconciliationTypes.swift` (`Discrepancy`, `HealResult`).
