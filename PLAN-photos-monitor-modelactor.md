# Plan: Background ModelActor for the Photos Library Monitor

Status: **proposed** (not scheduled)
Prereqs: PR #46 (multi-asset-id tracking), PR #47 (debounce / pause / off-main diff math)
Scope: `PhotosLibraryMonitor`, `PhotosImportSheet.trackedAssetCounts()`, app bootstrap

---

## 1. Problem

After PR #47, the monitor's per-recheck main-actor cost is one linear pass per
album: faulting `album.images` and reading each record's tracked asset ids.
Everything else (PhotoKit fetch, set math) already runs off the main actor.

That remaining pass is O(catalog) on the MainActor. For large catalogs
(50k–100k+ images) it can still produce a visible hitch per recheck —
debouncing and pausing make it *rare*, not *free*. The same pattern exists in
`PhotosImportSheet.trackedAssetCounts()`, which scans the full catalog on the
main actor when the import sheet opens (sliced with yields, but still
main-actor work).

The fix is to read SwiftData from a background context so record faulting
happens off the main thread entirely, exchanging only `Sendable` snapshots and
`PersistentIdentifier`s across actor boundaries.

## 2. Goals / Non-goals

**Goals**

- Zero O(catalog) work on the MainActor during library rechecks; main-actor
  cost becomes O(changed albums) resolution + publish.
- Same public monitor API (`deltas`, `recheckAll`, `recheck(album:)`,
  `pause`/`resume`, `clearDelta`) so UI consumers don't change.
- `trackedAssetCounts()` moves to the same background actor.

**Non-goals**

- No change to `AlbumDelta`'s consumer-facing shape (SidebarView badges,
  AlbumResyncSheet display/actions keep working with live `ImageRecord`s).
- No second source of truth: the background context is read-only; all writes
  stay on the main context per the project's concurrency rules.
- No CloudKit/store-format changes.

## 3. Current flow (post-#47) vs. target

```
Today (per album):
  [Main]   fault album.images, read ids           ← the remaining O(catalog) cost
  [Actor]  PhotoKit fetch (PhotosImportService)
  [Detach] computeDeltaCore (pure set math)
  [Main]   map indices → ImageRecords, publish

Target (per album):
  [DiffActor]  fetch + snapshot albums/images      ← O(catalog) moves here
  [Actor]      PhotoKit fetch (unchanged)
  [DiffActor]  computeDeltaCore (unchanged, pure)
  [Main]       resolve PersistentIdentifiers → ImageRecords, publish
```

## 4. Design

### 4.1 Snapshot types (new, `Sendable`)

```swift
struct AlbumSnapshot: Sendable {
    let persistentID: PersistentIdentifier
    let photosAlbumLocalIdentifier: String
    let images: [ImageIDSnapshot]
}

struct ImageIDSnapshot: Sendable {
    let persistentID: PersistentIdentifier
    let assetIds: [String]        // allPHAssetIdentifiers, read once
}
```

`PersistentIdentifier` is `Sendable & Hashable & Codable` — the designed
currency for crossing actor boundaries.

### 4.2 The background actor

```swift
@ModelActor
actor LibraryDiffActor {
    /// Snapshot every album that has a photosAlbumLocalIdentifier.
    func snapshotTrackedAlbums() throws -> [AlbumSnapshot]

    /// Per-Photos-album "assets accounted for" counts for the import sheet
    /// (union of tracked ids + legacy images without ids).
    func trackedAssetCounts() throws -> [String: Int]
}
```

- Created from the **shared** `ModelContainer` (`@ModelActor` synthesizes
  `init(modelContainer:)` and a serial executor bound to its own context).
  Never create a second container on the same store URL.
- **Instantiate a fresh actor per recheck pass.** A long-lived background
  context caches rows and can serve stale data after main-context saves;
  a per-pass context is cheap at debounced cadence and always reads the
  latest persisted state.

### 4.3 Monitor orchestration changes

- `start(modelContext:)` → `start(container: ModelContainer)`. The monitor
  keeps `container.mainContext` for resolution/publish and hands the container
  to `LibraryDiffActor` per pass. Call site: `LumiVaultApp` (line ~32) already
  owns the container.
- `recheckAll()`:
  1. `LibraryDiffActor.snapshotTrackedAlbums()` (off main).
  2. Per album: PhotoKit ids via `PhotosImportService` (unchanged), then
     `computeDeltaCore(photoIds:imageAssetIds:)` — callable straight from the
     diff actor since it's already `nonisolated` and pure.
  3. Hop to MainActor once per album with a `Sendable` result
     (added asset ids, removed/untrackable `PersistentIdentifier`s):
     resolve ids → `ImageRecord`s, build `AlbumDelta`, publish through the
     existing `updateDelta` (keeps `hasSameContent` no-op suppression).
- Debounce, pause/resume, `Task.yield()` pacing: unchanged.

### 4.4 Resolution on the main actor

```swift
// Resolve snapshot ids back to live records; drop anything that no longer
// resolves (deleted mid-flight) — the next recheck self-corrects.
let removed = removedIDs.compactMap { mainContext.registeredModel(for: $0) as ImageRecord? ?? fetchByID($0) }
```

- Use `registeredModel(for:)` first (already-faulted records), fall back to a
  `FetchDescriptor` on `persistentModelID`. **Never** force-resolve: a record
  deleted between snapshot and publish must be dropped, not crash.
- If any id fails to resolve, schedule one follow-up debounced recheck —
  the snapshot was stale.

### 4.5 `added: [PHAsset]` stays as-is

PHAssets are fetched on the import-service actor and carried in `AlbumDelta`
(`@unchecked Sendable`) exactly like today. No change.

## 5. Implementation steps

1. **Spike (½ day, de-risk first):** verify `@ModelActor` expands and compiles
   under this project's settings — Swift 6.2, strict concurrency,
   `SWIFT_DEFAULT_ISOLATION: MainActor`. Known friction: macro-generated
   members may need explicit `nonisolated` under default MainActor isolation.
   If the macro fights the settings, hand-roll the actor (custom executor is
   NOT needed — a plain actor owning a `ModelContext(container)` created
   inside the actor is equivalent; the context must simply never escape).
   **Go/no-go gate for the rest of the plan.**
2. Add snapshot types + `LibraryDiffActor` with `snapshotTrackedAlbums()` and
   unit tests against an in-memory container.
3. Rework `PhotosLibraryMonitor.recheckAll()`/`recheck(album:)` to the
   snapshot → diff → resolve pipeline (§4.3–4.4). `computeDeltaCore`,
   `computeDeltaParts` (test seam), debounce, and pause logic stay.
4. Move `PhotosImportSheet.trackedAssetCounts()` onto `LibraryDiffActor`;
   delete the main-actor scan and its yield-slicing.
5. Tests (see §6) + Instruments verification (see §7).

Estimated effort: **~1–1.5 days** including profiling, if the spike passes.

## 6. Testing

- `LibraryDiffActor.snapshotTrackedAlbums()` round-trip: seed in-memory
  container → snapshot off main → ids and asset-id arrays match.
- **Staleness semantics:** insert a record on the main context *without*
  saving → background snapshot must not see it; after `save()` it must.
  (Documents the visibility contract; the monitor's pause-during-import
  depends on it.)
- **Unresolvable ids:** delete a record after snapshotting → resolution drops
  it and doesn't crash; a follow-up recheck is scheduled.
- `trackedAssetCounts()` parity: same inputs produce the same counts as the
  current main-actor implementation (write this test *before* step 4 against
  the existing code, then port).
- Existing `PhotosLibraryMonitorDiffTests` keep passing via
  `computeDeltaParts` unchanged.

## 7. Acceptance criteria

- Time Profiler during a recheck burst (Photos syncing, 50k+ image catalog):
  no `snapshotTrackedAlbums`/faulting frames on the main thread; main-actor
  recheck slices < ~5 ms each.
- Sidebar badges, resync sheet contents, and post-resync refresh behave
  identically (manual pass over TEST-PLAN.md's sync scenarios).
- No new SwiftData multi-context warnings/crashes under Thread Sanitizer.

## 8. Risks

| Risk | Mitigation |
| --- | --- |
| `@ModelActor` vs `SWIFT_DEFAULT_ISOLATION: MainActor` friction | Spike first (step 1); hand-rolled actor fallback |
| Stale background reads after main-context saves | Fresh actor/context per pass; autosave keeps persisted state close to live |
| `PersistentIdentifier` of unsaved records is temporary | Monitor never snapshots mid-import (paused); resolution drops unknowns |
| Two contexts, one store — write conflicts | Background context is strictly read-only; all writes remain on mainContext |
| CLAUDE.md rule "keep SwiftData on MainActor" | Rule exists to prevent cross-actor `ModelContext` sharing; a self-contained `@ModelActor` honors the intent — update CLAUDE.md wording when this lands |

## 9. Out of scope / follow-ups

- Scoping rechecks by `PHChange.changeDetails(for:)` so only affected albums
  re-diff (orthogonal win, works with or without this plan).
- Snapshot-driven `AlbumDelta` (dropping live `ImageRecord`s from the UI
  boundary entirely) — bigger UI refactor, only worth it if resolution cost
  ever shows up in profiles.
