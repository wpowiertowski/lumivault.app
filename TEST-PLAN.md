# LumiVault — QA Test Plan

## Existing Automated Test Assessment

### Summary: 328 tests across 60 suites

| Rating | Suite | Tests | Assessment |
| -------- | ------- | ------- | ------------ |
| High Value | EncryptionServiceTests | 17 | Key derivation determinism, encrypt/decrypt round-trip (data + file), wrong key/AD rejection, nonce uniqueness, static method interop |
| High Value | EncryptPAR2IntegrationTests | 2 | Full encrypt-PAR2-corrupt-repair-decrypt pipeline, uncorrupted encrypted file passes PAR2 verification |
| High Value | EncryptionEdgeCaseTests | 4 | Empty data, ciphertext size = plaintext+16, 1MB large data round-trip, file-level encrypted size check |
| High Value | RedundancyServiceTests | 13 | Core data-integrity logic. Covers PAR2 2.0 encode, verify, corrupt-and-repair round-trips, split file format, par2cmdline interop (verify + repair), stale vol-file identification, edge cases. Irreplaceable. |
| High Value | CatalogServiceMergeTests | 5 | Union-by-SHA merge, timestamp precedence, dedup — exactly the logic that protects multi-device iCloud sync. |
| High Value | CatalogRemovalTests | 4 | Album removal, empty container pruning, single-image removal — validates catalog mutation correctness. |
| High Value | VolumeScanTests | 4 | Reconciliation scan: dangling locations, orphan detection, healthy pass, unmounted skip. Core integrity flow. |
| High Value | DeletionServiceTests | 7 | File removal from volumes, PAR2 companion cleanup, unmounted volume skip, bulk delete, edge cases. Real FS operations. |
| High Value | ReconciliationDiffTests | 5 | B2 diff logic: matched, dangling B2 IDs, orphans, PAR2 skip, mixed scenarios. Pure logic, well-structured. |
| High Value | PhotosLibraryMonitorDiffTests | 9 | Album diff core (PHAsset-free `computeDeltaParts`): additions only, removals only, mixed delta, no-change pass-through. Validates the Photos auto-sync logic without PhotoKit fixtures. |
| High Value | B2ServiceNetworkTests | 13 | End-to-end B2 REST flow via URLProtocol stub: authorize (Basic auth + 401), getUploadURL (auth gating + decode), uploadFile (headers, sha1, single-use URL), list pagination, fileExists hit/miss, delete file. |
| High Value | SyncServiceTests | 20 | push writes encoded catalog and creates parent dirs; pull returns nil/decodes/unions with local; push-then-pull round-trip; corrupt remote JSON propagates an error. Bypasses NSFileCoordinator via test-only init. |
| High Value | AsyncChannelTests | 5 | Bounded async channel: send/receive, backpressure blocks producer when full, finish ends consumer loop, cancel unblocks producers + terminates consumer, multi-producer/single-consumer race. |
| High Value | AsyncSemaphoreTests | 3 | Counting semaphore: wait suspends at zero, cancelAll resumes every waiter, wait-after-cancel does not suspend. The non-suspending fast paths are reached by these same tests, so the two assertion-free tests that only walked them were dropped. |
| Medium Value | B2ServiceHelperTests | 5 | SHA-1 known test vectors, HTTP response validation for success (299 — the range's upper edge) and error (401, 500) status codes |
| High Value | PipelineOrchestrationTests | 12 | The real eight-stage import pipeline end to end via `importFiles`: persistence + album + catalog + bytes on the volume, PAR2 recovery volumes mirrored beside the index, ciphertext really written (not just the record flags), converted extension agreed on by record/catalog/disk, exact dedup, second-album membership, a failing volume copy reported without dropping the import, an unreadable source skipped without stopping siblings, cancellation stopping short of the backlog, counters reconciling with what was persisted, and both halves of the album-deletion rule. |
| High Value | ReconciliationRepairTests | 9 | Corruption detection and auto-repair: a rotted file passes an existence scan and is caught by `verifyHashes`; repair from a healthy replica (asserted on the bytes, not the outcome enum); real PAR2 Reed-Solomon recovery; a mis-hashing replica refused; a traversing `relativePath` refused with the outside file proven untouched; unrepairable corruption reported rather than passed. |
| High Value | SyncCoordinatorTests | 10 | Catalog distribution to every registered volume, `reloadFromDisk` true vs false picking the on-disk vs in-memory catalog, iCloud/B2 skipped when disabled, a read-only volume survived (and proven to have failed), restore-from-file landing on disk and in the live service, a failed restore leaving the existing catalog intact, a disconnected volume skipped without stopping the healthy one. |
| High Value | EXIFExtractionTests | 7 | Real JPEGs carrying real EXIF/TIFF/GPS. The GPS hemisphere reconstruction is the point: a dropped negation files a photo on the wrong side of the equator without crashing or failing to decode. Plus capture settings (ISO from an array, vendor-padded Make/Model trimmed), the DateTimeOriginal fallback, in-memory extraction, and a non-image returning nil. |
| Medium Value | EXIFFormattingTests | 4 | The six formatted strings: aperture/ISO/focal length incl. the 35mm equivalent, megapixels needing both axes, altitude and coordinate precision, and a latitude without a longitude not being a fix. |
| Medium Value | KeychainStoreTests | 4 | Round-trip, update-in-place rather than duplicate, delete of an absent account, and account isolation. Gated with `.enabled(if:)` on the `CI` env var — a CI runner's keychain is typically locked. `B2Credentials` is deliberately uncovered: it persists under a fixed account, so testing it would overwrite real credentials. |
| Medium Value | CatalogBackupServiceTests | 5 | Volume backup write + decode, error on bad path, file restore round-trip, missing catalog error, orphan vol-file eviction |
| Medium Value | CatalogBackupRestoreTests | 1 | Volume restore happy path with full fixture hash verification |
| Medium Value | ImageConversionTests | 6 | JPEG conversion with extension change, valid output, dimension scaling, original format pass-through, below-max preservation. Tests exercise the shared `ImageConversionService.convertImage`. |
| Medium Value | HasherServiceTests | 3 | Fixture hash verification is the trust anchor for the entire test suite, for both `sha256` and `sha256AndSize`. Plus the empty-file known vector. |
| Medium Value | CatalogTests | 4 | Codable round-trip, optional fields, snake_case keys, file I/O. Necessary for CLI compatibility guarantee, but scenarios are basic. |
| Medium Value | PerceptualHashComputeTests | 3 | dHash `compute()` returns 8 bytes, deterministic output for same image, rejects non-image files |
| Medium Value | PerceptualHashTests | 5 | `hammingDistance` at both extremes (0 and 64 bits), a known mid-range value, the invalid-length guard, and the misaligned-slice regression that used to trap on SwiftData reads. Three further same-shape known-answer tests were dropped as duplicates. |
| Medium Value | SwiftDataModelTests | 5 | Album/image relationship through a real container, plus `imageRecordDefaults` pinning every default on the persisted record — including the media fields added after first release, since a changed default silently rewrites already-archived rows. |
| Low Value | PhotosSyncSchemaTests | 4 | Lightweight-migration smoke tests for the new optional `phAssetLocalIdentifier` / `photosAlbumLocalIdentifier` fields on legacy SwiftData stores. |
| Low Value | SnakeGameTests | 7 | Easter-egg Snake game state machine: initial segments, hold-before-start, tick movement, no-direct-reverse, wall collision, food growth/score, reset. |
| Low Value | FlappyGameTests | 5 | Easter-egg Flappy game state machine: hover-before-flap, flap impulse, gravity, floor collision, reset. |
| High Value | HydrationTests | 12 | Rebuilding SwiftData from `catalog.json`: empty store, idempotent upsert, local-only fields preserved, staleness detection (including the multi-album and skipped-entry catalogs where an entry-count comparison could never settle), deterministic album assignment for a multi-album image, tombstone application, and a 2,000-image pass. Guards the "restored successfully over an empty sidebar" class of bug. |
| High Value | SingleImagePAR2DeletionTests | 3 | Single-image deletion removes the `.vol0+N.par2` recovery volumes, leaves siblings' PAR2 sets intact, and derives the index name when the record carries none. |
| High Value | HealReplicasTests | 4 | Volume-to-volume replica healing: real bytes restored, failure reasons reported, traversing `relativePath` refused, unhealable discrepancy kinds ignored. |
| High Value | PipelinePhaseRoutingTests | 6 | Stage-to-stage routing over all 16 combinations of enabled phases: never forwards into a disabled stage, always terminates at the catalog sink. |
| High Value | CatalogMigrationTests | 6 | Legacy catalog + sidecar migration out of the sandbox container, never clobbering an existing catalog, plus library-as-storage-target resolution. |
| High Value | StallPolicyTests | 6 | iCloud-download watchdog arithmetic: doubling thresholds 1→512s over 10 attempts, slow-message suppression below 5s, retry countdown never negative. |
| Medium Value | PipelineItemTests | 4 | Converted filename reaches downstream stages; encrypted/converted/original URL precedence, including the conversion+encryption combination. |
| High Value | ImportProgressBoundsTests | 8 | Progress fraction stays within 0…1 across every phase and on the between-albums exit, and the removal phase is labelled and determinate. Two tests pin the *expected* fraction through the real `beginRun`/`beginAlbum`/`finishAlbum` sequence, so a dropped counter reset fails rather than being swallowed by the clamp. |
| Medium Value | ThumbnailCacheTests | 4 | Cache root is Application Support and not the purgeable `Caches`; sha-sharded layout for both sizes, miss reads nil, removal clears disk. |
| Medium Value | EnsureFileMirroredTests | 4 | Copy-stage mirroring skips a same-size destination and replaces truncated or empty leftovers. |
| Medium Value | CatalogPathResolutionTests | 5 | Catalog path override and tilde expansion via `resolveCatalogURL(override:)` — no writes to the process-wide `catalogPath` default — plus the wiring that accessor depends on, and the symlink-resolved library path that keeps container paths out of the UI. |
| Medium Value | ImageConversionFormatTests | 3 | HEIC output really decodes as `public.heic`; alpha stripped from RGBA sources for both JPEG and HEIC. |
| Medium Value | BookmarkResolverTests | 3 | Bookmark round-trip, no rewrite when not stale, corrupt data still throws. Asserts unconditionally — security-scoped bookmarks resolve fine in an unsandboxed test process. |
| High Value | ChannelCancellationDrainTests | 2 | `cancel()` does not discard buffered items, and a cancelled `runConversionStage` stops consuming instead of draining the backlog. The second drives a real pipeline stage, so reverting any stage's `break` to `continue` fails it. |
| High Value | SettingsSyncServiceTests | 8 | Settings document push/pull: local preferences written, volume order normalized so repeated syncs settle, newer remote applied, second sync is a no-op, encryption identity adopted without ever overwriting an existing local key, per-host volume slots merged. |
| High Value | B2LargeFileTests | 7 | Large-file B2 flow via URLProtocol stub: start/upload-part/finish, cancel posts the file id, small uploads stream from disk with the right SHA-1, size-based routing between the part and single-call APIs, and the raw-vs-percent-encoded filename each route requires. |
| High Value | CatalogMergeSanitizationTests | 3 | Merge drops entries whose filename or album key would traverse out of the album directory, and keeps clean ones — the sanitization that stops a tampered remote catalog from steering filesystem writes. |
| High Value | NearDuplicateClusteringTests | 4 | Near-duplicate grouping: transitive chains cluster, distinct groups stay separate, no matches yields no groups, a singleton never groups with itself. |
| High Value | PathComponentValidationTests | 3 | The shared path-component guard: ordinary names accepted, traversal and separators rejected, image validation requires every component. |
| Medium Value | MemoryBudgetSemaphoreTests | 4 | Weighted memory budget for the encryption/PAR2 stages: over-budget waits for a release, an oversized request runs solo rather than deadlocking, admission is FIFO, cancelAll resumes every waiter. |
| Medium Value | CatalogVideoSchemaTests | 4 | Video fields round-trip through JSON, image entries omit the video keys, legacy catalogs without them still decode, and merge combines them commutatively. Guards catalog.json backwards compatibility. |
| Medium Value | VideoRecordSchemaTests | 2 | `ImageRecord` media type: video fields persist through SwiftData, an unknown raw value reads back as image rather than trapping. The image-side defaults are pinned by `SwiftDataModelTests.imageRecordDefaults`. |
| Medium Value | VideoImportSettingsTests | 3 | The `includeVideos` UserDefaults key and its unset/true/false resolution, the drop filter accepting movies and images only, duration label formatting. |
| Medium Value | VideoThumbnailTests | 2 | Poster frame and duration probe from a generated video; non-video input throws. |
| Medium Value | FilenameDisambiguationTests | 2 | Content-derived filename suffixes: distinct shas never collide on one storage slot (pinning the exact `name~hash.ext` form), and extension-less names handled. |
| Medium Value | EXIFDataFormattingTests | 4 | Exposure string formatting: sub-second, long exposure, absent value, and zero (which used to trap). |
| Low Value | DeletedRecordGuardTests | 1 | A deleted `ImageRecord` detaches and its relationship stays readable, rather than faulting on a dangling reference. |
| Low Value | URLDescendantTests | 1 | Truth table for the descendant check that keeps writes inside their target volume. |

### Redundancy & Overlap

The suite was pruned from 302 to 281 tests against measured line coverage. The 21
removed tests were verified to contribute **zero** uniquely covered lines: running
the full suite and the pruned suite under `swift test --enable-code-coverage` both
report 3963/25067 lines, with no line covered by the old suite absent from the new
one. They fell into four groups:

- **Tautologies** — asserting a default against the literal that defines it
  (`ImportSettings.nearDuplicateThreshold == Constants.Dedup.nearDuplicateThreshold`,
  `includeVideos == true`), or that a pure function returns the same value twice.
- **Strictly weaker duplicates** — a shape/length check sitting next to a
  known-answer test for the same function (`sha1HashFixtureContent`), a 200 next to
  the 299 that actually probes the range boundary, a nil-`b2FileId` round-trip when
  the shared fixtures already carry nil.
- **Assertion-free tests** — three semaphore tests whose only claim was "this did
  not hang", walking fast paths the suspend/cancel tests already walk.
- **A shallow suite subsumed by a deeper one** — `PhotosImportProgressTests` set
  `fraction`'s inputs directly and checked the arithmetic, while
  `ImportProgressBoundsTests` drives the same property through the real
  `beginRun`/`beginAlbum`/`finishAlbum` sequence and so also catches the dropped
  counter reset (5233888) that the direct-assignment version could not. Its two
  genuinely unique assertions — the `.importing` 10% band and `.complete` reading
  exactly 1.0 — were folded into the deeper suite rather than dropped.

Zero coverage delta was the filter for *considering* a test, not the reason for
removing it: line coverage cannot see assertion strength. `deriveKeyDifferentSalts`
adds no lines over `deriveKeyDifferentPassphrases` but was **kept**, because it is
the only test that fails if the salt stops feeding the KDF. Same reasoning kept
`imageRecordDefaults`, which was extended with the media fields rather than deleted.

Among what remains, `deleteRemovesFilesFromVolume` vs `deleteAllFixtureFilesFromVolume`
differ only in batch size, but serve as single-file vs bulk regression guards.

### Coverage Status

Measured with `swift test --enable-code-coverage` (SwiftPM, no app host — see
README for why that differs from the Xcode figure).

| Scope | Covered | Total | % |
| --- | --- | --- | --- |
| **Non-view** (the gated number) | 5473 | 9042 | **60.5%** |
| Views | 233 | 16017 | 1.5% |
| Overall | 5706 | 25059 | 22.8% |

The headline number is capped at ~36% while views are untested, because SwiftUI
view code is 64% of the target. CI gates **non-view** coverage with a floor of
58% (`Scripts/coverage-gate.sh`) rather than the headline, which moves whenever a
settings screen is added or removed regardless of test quality.

| Area | Risk | Status |
| ------ | ------ | -------- |
| EncryptionService | High | **Covered** — 23 tests across 3 suites: key derivation, round-trips, wrong key/AD, nonce uniqueness, file ops, edge cases, encrypt-PAR2-decrypt integration |
| B2Service (network layer) | High | **Covered** — 25 tests: 5 pure helpers, 13 network methods via URLProtocol stub, 7 large-file tests. 83.7% |
| PipelinedImportCoordinator | High | **Covered, 72.7%** — the eight-stage pipeline runs end to end in tests via `importFiles`, which reaches the same `runImportPipeline` as the Photos path. Only `PhotosImportService` (entitlement-bound) stays out. This is what caught the inert cancellation. |
| ReconciliationService | High | **Covered, 79.2%** — corruption detection plus both repair strategies (healthy replica, PAR2 recovery) and both refusal paths (mis-hashing source, traversing path). |
| SyncCoordinator | Medium | **Partially covered, 49.6%** — catalog distribution, restore, and mutation helpers are covered via the injected init. iCloud monitoring (`startMonitoring`, metadata queries) still needs provisioning. |
| EXIFData | Medium | **Covered, 100%** — including GPS hemisphere reconstruction. |
| KeychainStore | Medium | **Covered locally, 94.3%** — gated off in CI where the keychain is locked. |
| B2Credentials | Medium | **Not covered, 0%, deliberately** — persists under a fixed keychain account, so testing save/load would overwrite the developer's real credentials. |
| PhotosImportService | Low | **Mostly not testable, 1.7%** — requires the Photos entitlement. `StallPolicy` is extracted and covered; the `PHAssetResourceManager` loop remains manual QA. It is 1328 lines and is single-handedly the largest drag on the non-view figure. |
| Volume sync (VolumeSyncSheet inline copy loop) | Medium | **Not unit-tested** — loop lives in a SwiftUI view. Manual QA (TC-8, TC-9). |
| SyncService | Medium | **Covered, 44.2%** — push/pull/merge covered; `startMonitoring`/`stopMonitoring` need iCloud. |
| ThumbnailService | Low | **Partially covered** — on-disk contract plus video poster frames; NSCache layer is manual QA. |
| SwiftUI views | Medium | **1.5%** — needs UI tests; see below. |

### UI tests

`UITests/` drives the real app binary. Each launch is given a throwaway library
via the `LUMIVAULT_UITEST_LIBRARY` launch-environment variable, which redirects
`Constants.Paths.libraryURL` and puts the SwiftData store in memory. That is both
a safety requirement — without it a UI-driven import writes junk albums into the
developer's real archive and rewrites its catalog.json — and what makes the tests
deterministic: they previously asserted against whatever the developer happened
to have imported, which is the real reason they were considered flaky.

The CI job is **non-blocking** (`continue-on-error: true`), but not for the reason
originally assumed. XCUIAutomation was thought to be unusable headless; it is not —
on the macOS runners the suite launches and executes normally. (It does fail on a
local machine that has not granted automation/accessibility permission to the test
runner, which dies with `Timed out while enabling automation mode` before executing
a single assertion. That is a local TCC issue, not a CI one.)

The job stays non-blocking because 5 of 12 tests currently fail on CI for reasons
that predate this branch and need diagnosis:

| Test | Status | Note |
| --- | --- | --- |
| `testOpenSettingsFromImportSheetActuallyOpensSettings` | passes | the cbf5f3a regression |
| `testPhotosImportOpensSheet`, `testImportCancelButtonExists` | pass | |
| `testSettingsTabsExist`, `testWindowExists` | pass | |
| `testToolbarImportButton`, `testToolbarNearDuplicatesButton` | pass | |
| `testSidebarExists` | **fails** | `nav.sidebar` is an identifier on a NavigationSplitView column; container identifiers are not reliably queryable |
| `testWelcomeScreenRestoreButtons` | **fails** | detail-column content not resolving; previously masked by `XCTSkipUnless` |
| `testB2CredentialFields`, `testEncryptionTabFields`, `testImportDefaultsToggles` | **fail** | all reach into the Settings window via `app.windows.element(boundBy:)`, which is fragile |

None of these had ever run in CI before, so they are newly *visible* rather than
newly broken. Making the job blocking requires fixing or retiring all five.

Known gap: the album context-menu test was removed rather than carried forward.
It skipped unless the sidebar already had an album, which was only ever true
because runs shared a real store; with a fresh store per launch it could only
ever skip. Restoring it needs a way to seed an album into the UI-test store,
which does not exist yet.

### Remaining Automated Test TODOs

These items would further improve coverage but require architectural changes:

| Item | Blocker | Effort |
| ------ | --------- | -------- |
| PipelinedImportCoordinator end-to-end | Phase-skipping wiring is now covered (PipelinePhaseRoutingTests) and the primitives before it. What remains — sentinel task, per-stage cancellation, `copyError` vs `error` isolation, `defer`-finish on abnormal exit — needs protocol-based injection of the six services the coordinator constructs. | Medium |
| SyncCoordinator orchestration | Hydration and catalog migration are now covered via static, context-injected entry points. The rest (iCloud monitoring, settings debounce, push-after-local-change) still orchestrates 3 services + UserDefaults + SwiftData and needs dependency injection. | Medium — requires constructor refactor |
| Hydration complexity (O(N) vs O(N²)) | Attempted and removed. CI measured 4x the catalog costing 8.5x the time *with* the batch-load fix in place (exponent ~1.5), because SwiftData's per-insert cost grows with store size — so no ratio threshold separates the fixed shape from the quadratic one. Counting `FetchDescriptor` executions would be the right guard, but `ModelContext` offers no seam. Correctness at 2,000 images is covered; the shape is not. | Blocked |
| ThumbnailService cache logic | The on-disk contract is covered (root, layout, miss, removal). The NSCache layer and regeneration-from-volume still need real image rendering, unreliable headless (CIContext renders all-white at small sizes). | Low — limited value vs manual QA |
| PerceptualHash visual distinctness | CIContext.render produces all-white pixels in headless test environments at 9x8 resolution; cannot reliably test that different images produce different hashes | Low — CI environment limitation |
| Post-deletion catalog push | `pushAfterLocalChange(reloadFromDisk:)` reloaded the catalog after a deletion, resurrecting a deleted album when the prior save had silently failed. Testing it needs `syncService`, `backupService`, UserDefaults and resolved volumes injected into `SyncCoordinator`, the way `SyncService` already allows via its test-only init. | Medium — requires constructor refactor |
| Three view-body bugs | The `VolumeSyncSheet` copy loop (data race on `ImageRecord`), detail-view failure states, and opening Settings from a modal sheet all live in SwiftUI view bodies. Automating them means XCUIAutomation (excluded from CI — needs a real app launch, flaky headless) or extracting the logic into observable models. Manual TC-8/TC-9 and TC-22 cover them; extract opportunistically if the code is touched again. | Out of scope |

---

## Video Support — Test Additions

Tracks the test work for `VIDEO-SUPPORT-PLAN.md`. The automated suites below now live
in `Tests/VideoSupportTests.swift` (catalog schema, SwiftData model, import
settings/filters, B2 large-file API, video thumbnails via a runtime-generated
AVAssetWriter fixture). The manual cases TC-26/27/28 remain to be executed on real
hardware before release.

### Automated suites

| Suite | With PR | Covers |
| ------- | --------- | -------- |
| CatalogVideoSchemaTests | PR 1 (schema) | `media_type`/`duration_seconds` encode/decode round-trip; legacy catalog (no video fields) decodes with nil → image; catalog containing videos re-encodes deterministically; `reconciled(with:)` commutativity over the new fields; `contentEquals` stability across a save/load round-trip |
| SwiftData migration smoke | PR 1 (schema) | Legacy store opens with defaulted `mediaTypeRaw = "image"` and nil duration (same pattern as PhotosSyncSchemaTests) |
| B2LargeFileTests | PR 2 (B2) | Via the existing URLProtocol stub: start_large_file → get_upload_part_url → upload_part (per-part SHA-1 headers, part numbering) → finish_large_file (part SHA-1 array); cancel_large_file on mid-flight failure; threshold routing (≤ 200 MB single-call, > 200 MB parts); single-call path streams from file instead of `Data(contentsOf:)` |
| VideoThumbnailTests | PR 3 (pipeline) | Poster frame from a fixture `.mov` writes 256/64px HEICs into the standard SHA-keyed cache; duration/dimension probe returns expected values; non-video input throws. (AVAssetImageGenerator decodes without a display, so this is headless-safe — unlike the CIContext-based image cases.) |
| Pipeline media-type routing | PR 3 (pipeline) | Video `PipelineItem` skips conversion (output URL == input, no re-encode); pHash skipped (stays nil); encryption size cap: over-cap video imports unencrypted and surfaces a warning, under-cap encrypts normally; catalog sink persists `media_type`/`duration_seconds` |
| PhotosLibraryMonitor scope | PR 4 (Photos) | `computeDeltaParts` parity when the tracked set includes video asset ids — badges must match the import scope in both includeVideos states |
| VideoImportSettingsTests | PR 4 (Photos) | `includeVideos` resolves from the Import Defaults key — unset reads true, and an explicit true/false is honoured |
| DeletionServiceTests / VolumeScanTests (extend) | PR 3/5 | Existing suites gain a video fixture: deletion removes video + PAR2 companion; reconciliation dangling/orphan/hash-verify paths treat videos identically |

**Fixture**: one committed sub-second ~100 KB H.264 `.mov` under `Tests/Fixtures` with
a pinned SHA-256, serving as the trust anchor the same way the image fixtures do.

### Known automation gaps (manual QA only)

| Area | Blocker |
| ------ | --------- |
| Photos video export (.fullSizeVideo selection, slow-mo export sessions, iCloud-offloaded downloads) | Requires Photos library entitlement + real assets — same limitation as image import (covered by TC-26) |
| AVKit playback (incl. decrypt-to-temp) | Needs a real app session; covered by TC-27 |
| Multi-GB behavior (PAR2 duration, memory ceiling, real B2 large-file upload) | Requires large real files + live B2; covered by TC-28 |

---

## UI Test Automation (XCUIAutomation)

### Summary: 12 UI tests in 1 suite (local environment only)

The `LumiVaultUITests` target uses XCUIAutomation (Xcode 26) to automate a subset of the manual test cases below. These tests are designed for **local development only** — they require a real app launch and are not suitable for headless CI.

| Test | Covers | What it validates |
| ------ | -------- | ------------------- |
| `testWelcomeScreenRestoreButtons` | TC-1 | Welcome view shows From File / From Volume restore buttons (skips if albums exist) |
| `testSidebarExists` | TC-21 | NavigationSplitView sidebar is present |
| `testToolbarImportButton` | TC-21 | Import from Photos toolbar button is accessible |
| `testToolbarNearDuplicatesButton` | TC-21 | Near-Duplicates toolbar button is accessible |
| `testWindowExists` | TC-21 | App window renders successfully |
| `testSettingsTabsExist` | TC-22 | All 8 settings tabs (General through Support) are accessible |
| `testB2CredentialFields` | TC-22 | B2 tab shows enable toggle |
| `testEncryptionTabFields` | TC-22 | Encryption tab shows passphrase field |
| `testPhotosImportOpensSheet` | TC-2 | Import button opens import sheet with cancel button |
| `testImportCancelButtonExists` | TC-4 | Cancel and Next buttons exist; Next is disabled without album selection |
| `testAlbumContextMenuDeleteExists` | TC-16 | Right-click album shows Delete Album context menu (skips if no albums) |
| `testImportDefaultsToggles` | TC-22 | Import Defaults tab shows PAR2 and near-duplicate toggles |

### Accessibility Identifiers

~65 `.accessibilityIdentifier()` modifiers have been added across 14 view files. Naming convention: `area.element` (e.g., `sidebar.albumList`, `import.cancel`, `b2.testConnection`).

Key identifier groups:
- **Navigation**: `nav.sidebar`, `toolbar.importPhotos`, `toolbar.nearDuplicates`
- **Welcome**: `welcome.restoreFile`, `welcome.restoreVolume`, `welcome.restoreB2`
- **Sidebar**: `sidebar.albumList`, `sidebar.album.<name>`, `sidebar.volumeStatus`
- **Grid**: `grid.container`, `grid.import`, `grid.photo.<sha256prefix>`
- **Settings tabs**: `settings.tab.general` through `settings.tab.support`
- **B2**: `b2.enable`, `b2.keyId`, `b2.appKey`, `b2.bucketId`, `b2.bucketName`, `b2.testConnection`, `b2.save`
- **Encryption**: `encryption.passphrase`, `encryption.confirmPassphrase`, `encryption.createKey`, `encryption.unlock`
- **Import flow**: `import.cancel`, `import.next`, `import.back`, `import.start`, `import.done`, `import.phaseLabel`
- **Import settings**: `importSettings.albumName`, `importSettings.year/month/day`, `importSettings.par2`, `importSettings.nearDupe`, `importSettings.encrypt`, `importSettings.b2Upload`
- **Import**: `import.dropZone`, `import.chooseFiles`, `import.importButton`, `import.cancel`
- **Other settings**: `general.*`, `volumes.*`, `importDefaults.*`, `integrity.scan`, `albums.*`

### Running UI Tests

```bash
# Build and run all UI tests
xcodebuild test -project LumiVault.xcodeproj -scheme LumiVault \
  -destination 'platform=macOS' -only-testing:LumiVaultUITests

# Run a specific UI test
xcodebuild test -project LumiVault.xcodeproj -scheme LumiVault \
  -destination 'platform=macOS' -only-testing:LumiVaultUITests/LumiVaultUITests/testSettingsTabsExist
```

### Recording UI Test Traces with Xcode 26

Xcode 26 introduces **XCUIAutomation recording** (WWDC25 Session 344) which auto-generates test code from your interactions with the app. This is the fastest way to create new UI tests.

**How to record a UI test:**

1. Open the project in Xcode: `open LumiVault.xcodeproj`
2. Open `UITests/LumiVaultUITests.swift`
3. Place your cursor inside a test method body (or create a new empty `func testSomething()`)
4. Click the **red record button** at the bottom of the editor (or **Product > Record UI Test**)
5. Xcode launches the app and records every interaction — clicks, typing, menu selections — as XCUIElement API calls
6. Perform the flow you want to test in the running app
7. Click the record button again to stop — Xcode inserts the generated code at your cursor position
8. Add `XCTAssert` / `XCTAssertTrue` / `XCTAssertEqual` assertions after the recorded actions to verify expected state
9. Clean up the generated code: replace fragile element queries with accessibility identifiers (e.g., `app.buttons["import.cancel"]` instead of `app.buttons["Cancel"]`)

**Tips for reliable recorded tests:**
- Always use `.accessibilityIdentifier()` queries over text-based queries — text changes break tests, identifiers don't
- Add `waitForExistence(timeout:)` before interacting with elements that appear asynchronously (sheets, popovers, alerts)
- Use `XCTSkipUnless` for tests that depend on app state (e.g., albums existing in the sidebar)
- Keep tests independent — each test launches a fresh app instance via `setUp`

### Manual Test Cases NOT Automated

| TC | Reason |
| ---- | -------- |
| TC-5 (Drag & Drop) | XCUIAutomation cannot simulate inter-process drag from Finder |
| TC-8, TC-9, TC-25 (Volumes) | Require physical external drive mount + NSOpenPanel interaction |
| TC-10, TC-19 (PAR2/Integrity) | Require file corruption between UI steps |
| TC-12, TC-13 (B2 Upload) | Upload verification requires external B2 API checks |
| TC-14 (iCloud Sync) | Requires two physical devices with same iCloud account |
| TC-18 (Reconciliation) | Requires pre-staged volume discrepancies |
| TC-23 (Edge Cases) | Require external failure conditions (full disk, network drop) |
| TC-24 (Tip Jar) | StoreKit sandbox interaction is unreliable in UI tests |

---

## Manual Test Plan

### Prerequisites

| Item | Details |
| ------ | --------- |
| macOS | 26+ |
| External volumes | 2 USB drives (formatted APFS or ExFAT), labeled distinctly (e.g., "QA-Vol-A", "QA-Vol-B") |
| Apple Photos | Library with at least 2 albums, each containing 5+ photos (mix of HEIC, JPEG, RAW if available) |
| Backblaze B2 | Test bucket with application key (read/write) |
| iCloud | Signed-in Apple ID with iCloud Drive enabled |
| Test images | 10+ images on disk (drag-and-drop import testing), including at least one duplicate pair |
| Test videos *(manual QA pending — TC-26/27/28)* | Photos album with edited, slow-mo, and iCloud-offloaded videos; on-disk `.mov`/`.mp4` files at ~150 MB, ~500 MB, and > 2 GB |

---

### TC-1: First Launch & Welcome Screen

| # | Action | Expected |
| --- | -------- | ---------- |
| 1.1 | Launch app with no prior data | Welcome view appears with restore options and arrow pointing to sidebar |
| 1.2 | Click "Detect Existing" | App searches for `~/.lumivault/catalog.json`. If found, shows import summary. If not, shows "not found" message |
| 1.3 | Click "From File..." | File picker opens, filtered to `.json` files |
| 1.4 | Select a valid catalog.json | Catalog imports, sidebar populates with year/album tree |
| 1.5 | Select an invalid file (e.g., .txt) | Graceful error, no crash, app remains on welcome screen |

---

### TC-2: Photos Library Import (Happy Path)

| # | Action | Expected |
| --- | -------- | ---------- |
| 2.1 | Menu bar > File > Import from Photos | Photos album picker sheet appears |
| 2.2 | Verify album list | Albums from Photos.app displayed with image-only counts (videos excluded), sorted alphabetically |
| 2.3 | Use search field | Filters albums by name in real-time |
| 2.4 | Change sort order (name/count/date) | Album list re-sorts correctly |
| 2.5 | Select an album, click "Next" | Import settings screen appears |
| 2.6 | Configure: PAR2 on, JPEG conversion off, near-dupe detection on | Settings reflected in summary |
| 2.7 | Click "Start Import" | Progress bar appears with phase labels (Importing, Hashing, PAR2, etc.). Pipeline runs phases concurrently — e.g., early images may be hashing while later images are still importing. |
| 2.8 | Wait for completion | "Complete" screen shows images added to album (`filesCataloged`) as primary count, plus duplicates skipped and any files that failed to import (`filesDropped`). Copied/Uploaded counts shown when applicable. Orange warning icon if any files dropped or errors occurred. |
| 2.9 | Check sidebar | New album appears under correct year/month/day |
| 2.10 | Click album in sidebar | Photo grid shows all imported thumbnails |

---

### TC-3: Photos Import with JPEG Conversion

| # | Action | Expected |
| --- | -------- | ---------- |
| 3.1 | Import an album with JPEG conversion ON, quality 85%, max dimension 2048px | Import completes without error |
| 3.2 | Inspect a file on volume | File is JPEG (`.jpg` extension), dimensions <= 2048px on longest edge |
| 3.3 | Verify SHA-256 in metadata inspector | Hash matches the converted JPEG, not the original HEIC |

---

### TC-4: Import Cancellation

| # | Action | Expected |
| --- | -------- | ---------- |
| 4.1 | Start a large album import (20+ photos) | Progress begins, phases advance as images flow through pipeline |
| 4.2 | Click "Cancel" during import | Import stops within 2-3 seconds. All pipeline tasks killed (sentinel cancels child tasks + channels). |
| 4.3 | Check sidebar | No partial/corrupt album entry created (empty album record deleted on cancel) |
| 4.4 | Check volumes | No partial files left on disk (staging directory cleaned up via defer) |
| 4.5 | Cancel during PAR2 phase specifically | PAR2 OperationQueue stopped via cancelFlag; channel backpressure unblocked via semaphore.cancelAll() |
| 4.6 | Cancel while a phase is blocked on backpressure | Producer unblocks immediately (AsyncSemaphore.cancelAll resumes all waiters) |

---

### TC-5: Drag & Drop Import

| # | Action | Expected |
| --- | -------- | ---------- |
| 5.1 | Drag 5 image files from Finder onto the app window | Import sheet appears with file list |
| 5.2 | Drag a folder containing images | All images inside the folder are listed |
| 5.3 | Drag a non-image file (.pdf, .txt) | File is filtered out; only images shown |
| 5.4 | Complete the import | Images appear in new album, thumbnails load |

---

### TC-6: Deduplication — Exact (SHA-256)

| # | Action | Expected |
| --- | -------- | ---------- |
| 6.1 | Import the same album twice | Second import reports all images as "deduplicated", 0 new copies |
| 6.2 | Check catalog.json | No duplicate SHA-256 entries in the album |
| 6.3 | Check volume | No duplicate files on disk |

---

### TC-7: Deduplication — Near-Duplicate (Perceptual Hash)

| # | Action | Expected |
| --- | -------- | ---------- |
| 7.1 | Import photos that include slight crops/edits of the same image | Near-duplicate warning appears during import (if detection enabled) |
| 7.2 | Open Library > Near Duplicates view | Duplicate pairs listed with similarity percentage |
| 7.3 | Verify Hamming distance threshold | Only pairs within threshold (default <5) are flagged |

---

### TC-8: Multi-Volume Mirroring

| # | Action | Expected |
| --- | -------- | ---------- |
| 8.1 | Settings > Volumes > Add Volume > select QA-Vol-A | Volume appears in list with label and ID |
| 8.2 | Import an album targeting QA-Vol-A | Files appear on QA-Vol-A under `year/month/day/albumName/` hierarchy |
| 8.3 | Add QA-Vol-B via Settings > Volumes | Second volume appears |
| 8.4 | Settings > Volumes > Sync to QA-Vol-B | Progress shown; files copied from QA-Vol-A to QA-Vol-B |
| 8.5 | Verify files on QA-Vol-B | Same directory structure, same file hashes as QA-Vol-A |
| 8.6 | Check image metadata inspector | StorageLocations shows entries for both vol-A and vol-B |
| 8.7 | Eject QA-Vol-A, then sync to QA-Vol-B again | Reports "deduplicated" for all files (already on target) |

---

### TC-9: Volume Removal

| # | Action | Expected |
| --- | -------- | ---------- |
| 9.1 | Settings > Volumes > Remove QA-Vol-B | Confirmation dialog appears |
| 9.2 | Confirm removal | Volume disappears from list |
| 9.3 | Check image storage locations | QA-Vol-B entries removed from all images |
| 9.4 | Files on QA-Vol-B | Remain on disk (removal only clears bookmarks/tracking, not files) |

---

### TC-10: PAR2 Error Correction

| # | Action | Expected |
| --- | -------- | ---------- |
| 10.1 | Import an album with PAR2 enabled | `.par2` index and `.vol0+N.par2` volume files created alongside each image |
| 10.2 | Right-click image > Verify Integrity | "Passed" result, green checkmark |
| 10.3 | Hex-edit an image file on the volume (corrupt ~5% of bytes) | — |
| 10.4 | Verify Integrity on the corrupted file | "Failed" — hash mismatch detected |
| 10.5 | Right-click > Repair | File repaired using PAR2 data; re-verify shows "Passed" |
| 10.6 | Compare repaired file hash to original | SHA-256 matches the original pre-corruption hash |

---

### TC-11: Encryption

| # | Action | Expected |
| --- | -------- | ---------- |
| 11.1 | Settings > Encryption > Set passphrase "test1234" | Passphrase saved, encryption enabled |
| 11.2 | Import an album with encryption ON | Files on volume are encrypted (not viewable in Finder preview) |
| 11.3 | Select encrypted image in grid | Thumbnail loads (decrypted in-memory for display) |
| 11.4 | Open detail view | Full-resolution decrypted preview shown |
| 11.5 | Metadata inspector | Shows "Encrypted: Yes", encryption nonce present |
| 11.6 | Change passphrase to "newpass" | — |
| 11.7 | Verify old encrypted files still decrypt | App should use stored per-file key derivation, NOT require the current passphrase to match |
| 11.8 | Import new album with new passphrase | New files encrypted with new key |

---

### TC-12: Backblaze B2 Cloud Upload

| # | Action | Expected |
| --- | -------- | ---------- |
| 12.1 | Settings > B2 > Enter application key ID, application key, bucket name | Credentials saved |
| 12.2 | Click "Test Connection" | Success message with bucket info |
| 12.3 | Import album with B2 upload enabled | Upload progress shown per-file; SHA-1 verification on upload |
| 12.4 | Check B2 bucket (via web console) | Files present at `year/month/day/albumName/filename` paths |
| 12.5 | Upload same album again | All files reported as "already exists" — no re-upload |
| 12.6 | Check `b2FileId` in metadata inspector | Populated for each uploaded image |

---

### TC-13: B2 Upload with PAR2

| # | Action | Expected |
| --- | -------- | ---------- |
| 13.1 | Import album with both PAR2 and B2 enabled | Both image and `.par2` files uploaded to B2 |
| 13.2 | Verify in B2 console | PAR2 files present alongside images |

---

### TC-14: iCloud Catalog Sync

| # | Action | Expected |
| --- | -------- | ---------- |
| 14.1 | Settings > iCloud > Enable sync | Sync status indicator appears |
| 14.2 | Import an album on Device A | Catalog updates locally and pushes to iCloud |
| 14.3 | Open LumiVault on Device B (same iCloud account) | Catalog pulls from iCloud; new album visible in sidebar |
| 14.4 | Import a different album on Device B | — |
| 14.5 | Return to Device A, trigger sync | Device B's album now visible; union merge preserves both |
| 14.6 | Simulate conflict: edit album on both devices while offline, then reconnect | Merge uses union-by-SHA + newest-timestamp-wins; no data loss |

---

### TC-15: Catalog Backup & Restore

| # | Action | Expected |
| --- | -------- | ---------- |
| 15.1 | After exporting to volumes and B2, check each volume root | `catalog.json` present on each mounted volume |
| 15.2 | Check B2 bucket | `catalog.json` uploaded |
| 15.3 | Delete local app data (reset SwiftData container) | — |
| 15.4 | Relaunch app | Welcome screen appears |
| 15.5 | Restore from volume > select catalog.json on QA-Vol-A | Full catalog restored, sidebar repopulated |
| 15.6 | Repeat from B2: Settings > Restore from B2 | Catalog downloaded and restored from cloud |

---

### TC-16: Album Deletion

| # | Action | Expected |
| --- | -------- | ---------- |
| 16.1 | Right-click album in sidebar > Delete | Confirmation dialog with count of images and affected locations |
| 16.2 | Confirm deletion | Progress indicator shows phases: volumes, B2, catalog |
| 16.3 | Check sidebar | Album removed from tree |
| 16.4 | Check volumes | Image files and PAR2 companions deleted |
| 16.5 | Check B2 | Files deleted from bucket |
| 16.6 | Check empty parent directories | Cleaned up if album was the only occupant |

---

### TC-17: Single Image Deletion

| # | Action | Expected |
| --- | -------- | ---------- |
| 17.1 | Select image in grid > Delete (toolbar or context menu) | Confirmation dialog |
| 17.2 | Confirm | Image removed from grid, files deleted from volumes and B2 |
| 17.3 | Remaining images in album | Unaffected, counts updated |
| 17.4 | If last image in album | Album should remain (empty) or be pruned — verify behavior matches design intent |

---

### TC-18: Storage Reconciliation

| # | Action | Expected |
| --- | -------- | ---------- |
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
| --- | -------- | ---------- |
| 19.1 | Select image > Metadata Inspector > Verify Integrity | Re-hashes file, shows pass/fail with actual vs stored hash |
| 19.2 | Bulk verify (Settings > Integrity > Verify All) | Batch progress, summary of pass/fail counts |
| 19.3 | Corrupt a file on disk, then verify | Mismatch detected, repair option offered |

---

### TC-20: Thumbnail Behavior

| # | Action | Expected |
| --- | -------- | ---------- |
| 20.1 | Import album with HEIC images | Grid thumbnails render within 2 seconds |
| 20.2 | Import RAW images (CR2/CR3/NEF/ARW/DNG) | Thumbnails render correctly (may be slower) |
| 20.3 | Scroll rapidly through 100+ image grid | No blank thumbnails, no memory spike, smooth scrolling |
| 20.4 | Quit and relaunch | Cached thumbnails load instantly (no regeneration) |
| 20.5 | Switch between grid (256px) and list (64px) views | Correct resolution used for each mode |

---

### TC-21: Navigation & UI

| # | Action | Expected |
| --- | -------- | ---------- |
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
| --- | -------- | ---------- |
| 22.1 | General tab | App preferences displayed and editable |
| 22.2 | Import Defaults tab | Format, quality, max dimension, PAR2 toggle, near-dupe toggle — all persist after closing settings |
| 22.3 | Volumes tab | Lists registered volumes with mount status |
| 22.4 | iCloud tab | Sync toggle, last sync timestamp |
| 22.5 | B2 tab | Credential fields, test connection button, setup guide link |
| 22.6 | Encryption tab | Passphrase field, enable/disable toggle |
| 22.7 | Integrity tab | Reconciliation and verification buttons |
| 22.8 | Support tab | Tip jar with 4 tiers, purchase flow via StoreKit 2 |

---

### TC-23: Edge Cases & Error Handling

| # | Action | Expected |
| --- | -------- | ---------- |
| 23.1 | Import to a full disk (no space) | Graceful error with message, no partial corruption |
| 23.2 | Eject volume during import | Import fails with error, no crash, partial files cleaned up |
| 23.3 | Invalid B2 credentials | "Test Connection" shows clear error message |
| 23.4 | Network disconnection during B2 upload | Upload fails gracefully, retry possible |
| 23.5 | Import album with 0 photos | Empty album created or rejected — document behavior |
| 23.6 | Photo with no EXIF data | Imports successfully with default/empty metadata |
| 23.7 | Filename with special characters (spaces, accents, emoji) | Handled correctly across export, volume copy, B2 upload |
| 23.8 | Very large image (>50MB RAW) | Imports without timeout or memory crash |
| 23.9 | Photos library permission denied | App shows permission prompt, Settings link to System Preferences |
| 23.10 | Pipeline backpressure: import 50+ images with PAR2 (slow) and no B2 | PAR2 phase should not cause unbounded memory growth; earlier phases pause via channel backpressure when PAR2 falls behind |
| 23.11 | Eject volume mid-pipeline during copy phase | Copy phase errors are per-item; remaining pipeline phases continue for other items; errors shown in completion screen |

---

### TC-24: Tip Jar (StoreKit 2)

| # | Action | Expected |
| --- | -------- | ---------- |
| 24.1 | Settings > Support | 4 tip tiers displayed with prices |
| 24.2 | Tap a tip tier | StoreKit purchase sheet appears |
| 24.3 | Complete purchase (sandbox) | Thank-you confirmation shown |
| 24.4 | Cancel purchase | No error, returns to tip jar |

---

### TC-25: Security-Scoped Bookmarks

| # | Action | Expected |
| --- | -------- | ---------- |
| 25.1 | Add volume, quit app, relaunch | Volume still accessible (bookmark persisted) |
| 25.2 | Rename external volume in Finder | Bookmark resolves to new name; access works or stale bookmark detected |
| 25.3 | Eject and re-insert volume | Access restored via bookmark without re-adding |

---

### TC-26: Video Import *(manual QA pending)*

Prerequisites: a Photos album containing a mix of photos and videos, including at least
one edited video, one slow-mo, and one iCloud-offloaded (not downloaded) video.

| # | Action | Expected |
| --- | -------- | ---------- |
| 26.1 | Open Photos album picker | Albums show separate photo and video counts (e.g., "42 photos · 3 videos") |
| 26.2 | Import settings: "Include videos" ON | Import ingests both photos and videos; total count matches picker |
| 26.3 | Import settings: "Include videos" OFF | Only photos imported; behavior identical to pre-video releases; sidebar sync badges do not report the skipped videos as pending |
| 26.4 | Import an edited video | Edited render is imported (`.fullSizeVideo` or export-session render), not the unedited original; original filename preserved |
| 26.5 | Import a slow-mo video | Export-session render succeeds; playback shows the slow-mo effect |
| 26.6 | Import an iCloud-offloaded video (multi-hundred MB) | Download proceeds with health status; watchdog does not spuriously cancel while chunks arrive |
| 26.7 | Import with JPEG/HEIC conversion + max dimension configured | Videos are passed through untouched (same bytes/extension); photos convert as usual |
| 26.8 | Import the same videos again | All deduplicated by SHA-256, 0 new copies |
| 26.9 | Drag a `.mov`/`.mp4` from Finder onto the app (TC-5 extension) | Video accepted by drop filter and file picker; imports through the same pipeline |
| 26.10 | Check catalog.json | Video entries carry `media_type: "video"` and `duration_seconds`; photo entries unchanged |
| 26.11 | Open the new catalog in a pre-video app version | Catalog decodes; videos appear as entries with broken previews but no crash or data loss |

---

### TC-27: Video Playback & Thumbnails *(manual QA pending)*

| # | Action | Expected |
| --- | -------- | ---------- |
| 27.1 | Grid view of a mixed album | Videos show poster-frame thumbnails with duration badge + play glyph; posters are not black frames |
| 27.2 | Open a video in detail view | Video plays inline (AVKit player) with audio; images keep the existing preview |
| 27.3 | Metadata inspector on a video | Shows duration, resolution, codec, hash, PAR2, storage locations; no EXIF section |
| 27.4 | Import a video with encryption ON (under size cap) | File on volume is ciphertext; grid poster still renders (generated pre-encryption) |
| 27.5 | Play an encrypted video | Decrypts to temp and plays; temp file removed after leaving the view |
| 27.6 | Delete thumbnail cache, rescroll grid | Poster regenerated from volume original (decrypt-to-temp path for encrypted) |
| 27.7 | Load video preview from B2 (volumes ejected) | Downloads, (decrypts,) and plays |

---

### TC-28: Large Video Handling *(manual QA pending)*

Prerequisites: videos of ~150 MB, ~500 MB, and > 2 GB; B2 test bucket.

| # | Action | Expected |
| --- | -------- | ---------- |
| 28.1 | Import ~150 MB video with B2 ON | Single-call upload path; memory stays flat (streamed from file) |
| 28.2 | Import ~500 MB video with B2 ON | Large-file API used (parts visible in B2 console as one finished file); `b2FileId` recorded; re-import reports "already exists" |
| 28.3 | Cancel import mid large-file upload | `b2_cancel_large_file` called; no orphaned unfinished large files in bucket |
| 28.4 | Import > 2 GB video with encryption ON | File imported **unencrypted**; completion screen surfaces the size-cap warning; no memory spike |
| 28.5 | PAR2 on a multi-GB video | Recovery files generated (~10%); progress advances; verify + corrupt-and-repair round-trip passes (TC-10 procedure) |
| 28.6 | Delete a large video (TC-16/17 extension) | Removed from volumes, B2 (large-file version), catalog, SwiftData |
| 28.7 | Reconciliation with a video fixture (TC-18 extension) | Dangling/orphan/hash-mismatch detection and repair work identically to images |

---

## Priority Matrix

### P0 — Must Pass (data loss risk)

- TC-2: Photos Import (pipelined flow)
- TC-4: Import Cancellation (pipeline teardown — sentinel kills all tasks + channels)
- TC-6: SHA-256 Dedup
- TC-8: Multi-Volume Sync
- TC-10: PAR2 Error Correction
- TC-11: Encryption
- TC-15: Catalog Backup & Restore
- TC-16: Album Deletion
- TC-18: Reconciliation
- TC-23.1-23.2: Disk full / eject during import
- TC-23.10: Pipeline backpressure under slow PAR2

### P1 — Should Pass (functionality risk)

- TC-3: JPEG Conversion
- TC-5: Drag & Drop
- TC-12: B2 Upload
- TC-14: iCloud Sync
- TC-17: Single Image Deletion
- TC-19: Integrity Verification
- TC-25: Bookmarks
- TC-23.11: Volume eject mid-pipeline

### P2 — Nice to Verify (UX/polish)

- TC-1: Welcome Screen
- TC-7: Near-Duplicate
- TC-13: B2 PAR2
- TC-20: Thumbnails
- TC-21: Navigation UI
- TC-22: Settings
- TC-24: Tip Jar
- TC-23.5-23.9: Edge cases

### Video support additions *(video support shipped — manual QA pending)*

- P0: TC-26.2-26.3 (import scope + badge consistency), TC-26.8 (video dedup),
  TC-26.11 (old-version catalog compatibility), TC-28.3 (large-upload cancel cleanup),
  TC-28.4 (encryption size cap), TC-28.5 (PAR2 on multi-GB video)
- P1: TC-26.4-26.6 (edited/slow-mo/iCloud videos), TC-27.4-27.5 (encrypted video
  poster + playback), TC-28.1-28.2 (B2 upload paths), TC-28.6-28.7 (deletion,
  reconciliation)
- P2: TC-26.1/26.9-26.10, TC-27.1-27.3/27.6-27.7
