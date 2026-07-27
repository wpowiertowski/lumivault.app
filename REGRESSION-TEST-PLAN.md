# LumiVault — Bug-Fix Regression Coverage Plan

Companion to [TEST-PLAN.md](TEST-PLAN.md). That document describes what the suite
covers today; this one works backwards from **every bug actually fixed on `main`**
and asks a single question per bug: *if someone reintroduced this tomorrow, would
CI catch it?*

Scope: all 50 commits on `main` (`54fb0f3` … `12632f7`). 28 of them fix defects.

> **Status:** phases 0–4 are implemented; phase 5 is partial. The suite went from
> 228 to 295 tests. See §7 for what landed and §7.1 for what is deliberately
> outstanding. The status column in §2 still describes coverage *before* this
> work — it is the audit that motivated the plan, kept as written.

---

## 1. Headline findings

**Finding 1 — CI cannot see two of the three build environments.**
`.github/workflows/ci.yml` runs `xcodebuild build` (app target only) and
`swift test` (SwiftPM). It never runs `xcodebuild test`, never builds Release, and
never regenerates the `.xcodeproj`. Three shipped bugs were invisible to it by
construction:

| Bug | Why CI missed it |
| --- | --- |
| `12632f7` — app built *nonisolated*, corrupting the main-bound `ModelContext` | `Package.swift`'s `.defaultIsolation(MainActor)` applies under SwiftPM, so `swift test` was green while the Xcode-built app diverged. Nothing asserted `-default-isolation` reached the compiler. |
| `b98a4da` — `AlbumDelta` data race | Xcode Cloud rejected it; GH CI and local Xcode passed. Toolchain drift, now partly mitigated by the `XCODE_VERSION` pin. |
| `e824865` — `[weak self]` in a nested closure | Same class: newer toolchain, different diagnostic. |

**Finding 2 — the fix commits are honest about testing, and the gaps cluster.**
Of the 28 defect fixes, **11 shipped with a regression test, 4 shipped partial
coverage, and 13 shipped with none.** The untested 13 are not random — they sit in
five areas that share one property: *no seam to call them from a test.*

1. The import pipeline's orchestration (cancellation, phase wiring, filename propagation)
2. `PhotosImportService`'s watchdog / stall-retry / circuit breaker
3. `SyncCoordinator.hydrateSwiftData` and the launch/restore rebuild paths
4. Path & storage resolution (`StorageResolver`, catalog migration, `resolvedCatalogURL`)
5. Everything that lives inside a SwiftUI view body

**Finding 3 — the most recent bug (`519c0d1`, B2 `%20` album fork) is one
character away from being caught by a test that already exists.**
`uploadImageRoutesLargeFilesThroughPartAPI` uploads to `remotePath: "big.mov"`.
Change that fixture to `"2024/06/12/Album Name/big.mov"` and assert the JSON body
of `b2_start_large_file` and the `X-Bz-File-Name` header of the single-call path
encode *differently*, and the bug is permanently fenced. This is the cheapest
high-value item in the plan.

**Finding 4 — the suite is only enforced by a local pre-commit hook.**
No hook is committed (`core.hooksPath` unset, `.git/hooks` empty). CI is the only
shared gate, which makes Finding 1 more serious than it looks.

---

## 2. Bug inventory and coverage status

Status legend: **✅ Covered** (a CI test fails if reintroduced) · **◐ Partial**
(related logic covered, the specific failure mode is not) · **❌ None**.

| # | Commit | Bug scenario | Failure mode | Status | Guard proposed |
| --- | --- | --- | --- | --- | --- |
| 1 | `54fb0f3` | Pipelined import converted to JPEG/HEIC but never propagated the converted filename downstream | Records and volume copies carried `.HEIC` extensions over JPEG bytes | ❌ | T1 |
| 2 | `b428117`a | `pushAfterLocalChange` reloaded the catalog after a deletion | Deleted album resurrected when the prior save had silently failed | ❌ | T14 |
| 3 | `b428117`b | CIImage-based HEIC encoding silently failed | "Converted" files stayed JPG; no error surfaced | ❌ | T2 |
| 4 | `f03135d` | Album deletion keyed off empty/stale `storageLocations` | Deletion silently no-opped; files orphaned on volumes and B2 | ✅ | — |
| 5 | `abe7b51` | Pipeline phases used `continue` on cancellation, draining channel buffers; `PhotosImportService` had no cancel check | Cancel kept importing for the length of the buffer | ❌ | T5 |
| 6 | `b97ed6d` | Single-image deletion removed `<name>.par2` but not `<name>.vol0+N.par2` | Orphan recovery volumes accumulate on every volume forever | ❌ | T3 |
| 7 | `25a3a7c`a | Stale bookmarks threw instead of refreshing | Volumes became inaccessible after a reboot | ❌ | T8 |
| 8 | `25a3a7c`b | Alpha channel not stripped before JPEG/HEIC encode | Corrupt output from RGBA sources | ❌ | T2 |
| 9 | `25a3a7c`c | `VolumeSyncSheet` copy loop concurrency | Data race on `ImageRecord` across isolation | ❌ | (view — see §6) |
| 10 | `154c011` | Catalog/sidecar/PAR2 uploads bypassed `withRetry` | One flaky request failed the entire catalog backup | ❌ | T11 |
| 11 | `c4cf7ee` | `writeData` had no cancellation/timeout; orphaned assetsd requests | Import wedged; assetsd refused with 46104 | ◐ | T6, T7 |
| 12 | `55e400e` | Photos import buffered whole albums; B2 retries too thin | Memory spikes, transient upload failures | ◐ | T11 |
| 13 | `5233888`a | No retry for stalled iCloud downloads (10-min hard skip) | Import parked for minutes on an assetsd stall | ❌ | T6 |
| 14 | `5233888`b | `filesCataloged` not reset between albums | Progress bar exceeded 100% when a later album was smaller | ❌ | T4 |
| 15 | `aedc03b` | Slow-download banner fired at half the attempt-0 threshold | Sub-second UI flicker on every brief hiccup | ❌ | T6 |
| 16 | `bf00a05` | Thumbnails stored in `Caches`, purged by macOS; no regeneration | Grid went blank after disk pressure | ❌ | T12 |
| 17 | `147b362` | Detail view couldn't distinguish disconnected volume from missing file | Misleading "Unable to load preview" | ❌ | (view — see §6) |
| 18 | `b98a4da` | Toolchain drift: `AlbumDelta` Sendable inference | Xcode Cloud build failed; GH CI green | ◐ | C1, C4 |
| 19 | `1a85372` | Orphan `catalog.json.vol*.par2` never evicted on backup | Stale recovery volumes accumulate on each volume | ✅ | — |
| 20 | `cbf5f3a` | `NSApp.sendAction(showSettingsWindow:)` from inside a modal sheet | "Open Settings" buttons did nothing | ❌ | (view — see §6) |
| 21 | `8cef649` | Restore wrote `catalog.json` but never hydrated SwiftData | "Restored successfully" over an empty sidebar | ❌ | T9 |
| 22 | `f3c5fae` | Catalog path components unvalidated; B2 creds in UserDefaults | Path traversal via catalog contents; creds at rest | ✅ (traversal) ◐ (keychain) | T13 |
| 23 | `2f44cfb` | Catalog inside the sandbox container; import dead-ended with no storage | **App Store rejection** (2.4.5(i) and 2.1(a)) | ❌ | T10 |
| 24 | `5568b41` | No way to restore a replica missing from one target | Manual recovery only | ❌ | T15 |
| 25 | `e824865` | `[weak self]` inside a strongly-capturing outer closure | Xcode Cloud build failure | ✅ (build job) | C4 |
| 26 | `b151c71`a | `performSync()` merged and saved but never hydrated | Second Mac showed an empty library | ❌ | T9 |
| 27 | `b151c71`b | Per-device PBKDF2 salt | Encrypted files undecryptable on any other Mac | ✅ | — |
| 28 | `0034bda` | Conversion output collided in a shared staging dir | Duplicated-with-edits photos collapsed into one; wrong bytes archived under a recorded hash | ✅ | — |
| 29 | `f171795` | Monitor work on the main actor's critical path | Periodic UI stalls | ◐ | T16 |
| 30 | `6dd8ad4` | Sync echo loop + O(N²) hydration | Main thread hung every ~2s | ✅ (loop) ❌ (O(N²)) | T16 |
| 31 | `1da8a89`a | `merge()` non-convergent; no deletion propagation | Write loop could reappear; deletions resurrected by a peer | ✅ | — |
| 32 | `1da8a89`b | `importRenderedAsset` could wedge on a never-firing PhotoKit callback | Process-global gate held forever | ❌ | T7 |
| 33 | `1da8a89`c | Launch hydration didn't rebuild on catalog/store count mismatch | A reset store never repopulated | ❌ | T9 |
| 34 | `519c0d1` | `startLargeFile` sent the percent-encoded name in a JSON body | Albums forked into `Album Name/` **and** `Album%20Name/` on B2 | ❌ | T0 |
| 35 | `12632f7`a | `SWIFT_DEFAULT_ISOLATION` silently ignored by the toolchain | App ran coordinators off-main; `EXC_BAD_ACCESS` in `@Query` | ❌ | C1, C2, C3 |
| 36 | `12632f7`b | Thumbnail write-back to a detached record | Trap on a photo removed mid-regeneration | ✅ | — |
| 37 | `12632f7`c | Removal progress labelled "Importing from Photos" | Mislabeled, indeterminate progress | ❌ | T4 |

---

## 3. Plan — Part A: CI changes (do first, no product code touched)

These close Finding 1. Each is a self-contained edit to
`.github/workflows/ci.yml` unless noted.

### C1 — Assert `-default-isolation MainActor` reaches the compiler

The single most valuable check in this document: it guards the root cause of the
worst shipped bug, and it costs nothing because the build already runs.

In the existing `build` job, tee the build log and grep the actual `swift-frontend`
invocation for the app target:

```yaml
      - name: Build macOS target
        run: |
          set -o pipefail
          xcodebuild -scheme LumiVault -destination "generic/platform=macOS" \
            -configuration Debug CODE_SIGNING_ALLOWED=NO build | tee build.log

      - name: Assert MainActor default isolation reached the compiler
        run: |
          grep -q -- '-default-isolation MainActor' build.log || {
            echo "::error::App target compiled WITHOUT -default-isolation MainActor."
            echo "See project.yml — SWIFT_DEFAULT_ISOLATION alone is silently ignored."
            exit 1
          }
```

Grep the log, not `-showBuildSettings`: the whole point of `12632f7` is that the
build *setting* was present while the compiler *flag* was not.

### C2 — Never commit the generated project

`CLAUDE.md` used to require regenerating the committed `.xcodeproj` after any
`project.yml` change. Nothing enforced it, so a correct `project.yml` could sit
next to a stale `project.pbxproj` — exactly how a build-setting fix silently fails
to ship.

A drift check was the first answer, but removing the artifact is strictly better:
`LumiVault.xcodeproj` is now gitignored and generated from `project.yml` by every
consumer, so it cannot drift by construction.

- Each CI job that needs it runs `brew install xcodegen && xcodegen generate`.
- Xcode Cloud generates it in `ci_scripts/ci_post_clone.sh`, which runs after the
  clone and before the build. **This file is load-bearing for App Store
  releases** — without it Xcode Cloud cannot find a project.
- `make generate` (or `make xcode`) covers local clones.

The build job additionally greps the *generated* `project.pbxproj` for
`-default-isolation MainActor`, so a `project.yml` regression is named directly
instead of being inferred from a build-log miss.

A side benefit: adding a new test file no longer needs any project bookkeeping,
because `project.yml` sources the whole `Tests` directory.

### C3 — Add an `xcodebuild test` job

`swift test` and `xcodebuild test` compile the app target under *different*
isolation defaults today. Running only the former is what let `12632f7` reach
users. Run the unit bundle under Xcode, and compile-only the UI target (UI tests
stay out of CI per TEST-PLAN §"UI Test Automation"):

```yaml
      - name: Run unit tests under Xcode
        run: |
          xcodebuild test -project LumiVault.xcodeproj -scheme LumiVault \
            -destination 'platform=macOS' -only-testing:LumiVaultTests \
            CODE_SIGNING_ALLOWED=NO

      - name: Compile UI test target (no execution)
        run: |
          xcodebuild build-for-testing -project LumiVault.xcodeproj \
            -scheme LumiVault -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Keep `swift test` as well — it is faster feedback and it is what the local
pre-commit hook runs. Cost: roughly one extra macOS runner build. Mitigate by
gating the xcodebuild-test job on `push` to `main` plus PRs that touch
`project.yml`, `Package.swift`, or `LumiVault/**`, if runner minutes matter.

### C4 — Fail loudly on a missing pinned Xcode

`sudo xcode-select -s` succeeding is not proof the pinned version is active. Add a
version assertion after the select step so a runner-image change surfaces as a
red build rather than silent toolchain drift (bug #18, #25):

```yaml
      - name: Verify Xcode version
        run: |
          actual="$(xcodebuild -version | head -1 | awk '{print $2}')"
          [ "$actual" = "$XCODE_VERSION" ] || {
            echo "::error::Expected Xcode $XCODE_VERSION, got $actual"; exit 1; }
```

### C5 — Release-configuration archive

The `Makefile`'s `test` target already archives Release locally; CI only builds
Debug. `-O`-only diagnostics therefore reach Xcode Cloud first. Add the archive
step to the build job (`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`), or as
a `main`-only job if PR latency matters.

### C6 — Commit the pre-commit hook

Add `.githooks/pre-commit` running `swift test`, and document
`git config core.hooksPath .githooks` in `CLAUDE.md`. Makes the convention
referenced across commit messages reproducible for new clones.

---

## 4. Plan — Part B: tests that need no refactor

Everything here can be written against the existing API surface today.

**T0 — B2 remote-path encoding (bug #34).** *Extend* `B2LargeFileNetworkTests`.
- Upload a >200 MB sparse fixture to `remotePath: "2024/06/12/Album Name/big.mov"`;
  assert the `b2_start_large_file` JSON body's `fileName` is **exactly**
  `2024/06/12/Album Name/big.mov` — no `%20`.
- Upload a small file to the same path; assert the `X-Bz-File-Name` header **is**
  percent-encoded (`Album%20Name`).
- One test asserting both paths agree after decoding — the invariant that actually
  broke: *the two routes must land in the same B2 folder.*
- Repeat for a filename containing `~` (already noted as B2-safe in `0034bda`) and
  a non-ASCII character.

**T1 — Converted filename propagation (bug #1).** New `PipelineItemTests`.
`PipelineItem.activeFilename` / `activeFileURL` are `nonisolated` computed
properties on a `Sendable` struct — directly testable.
- `convertedFilename` set → `activeFilename` returns it, not `originalFilename`.
- Precedence: `encryptedURL` > `convertedURL` > `fileURL`.
- Conversion + encryption together still yields the converted *name* with the
  encrypted *URL* — the combination that made records disagree with bytes.

**T2 — HEIC encode and alpha stripping (bugs #3, #8).** *Extend* `ImageConversionTests`.
- `.heic` conversion produces a file whose `CGImageSource` type is
  `public.heic` and whose extension is `.heic` (guards the silent CIImage failure
  that left JPGs behind).
- An RGBA PNG fixture converted to JPEG and to HEIC produces a valid image with no
  alpha channel (`CGImageAlphaInfo` is `none`/`noneSkipLast`).
- Requires one committed RGBA fixture with a pinned SHA-256, following the existing
  fixture convention in `TestFixtures.swift`.

**T3 — Single-image PAR2 volume cleanup (bug #6).** *Extend* `DeletionServiceTests`.
The existing `deleteRemovesPAR2Companion` only exercises whole-album removal (it
asserts the directory is gone), and `deleteSingleImagePreservesOtherFiles` passes
`par2Filename: ""`. Neither can see this bug.
- `materializeVolumeWithPAR2`, delete **one** image with `entireAlbum: false`,
  assert *no* `<name>.vol*.par2` remains and the siblings' PAR2 sets are intact.
- Same with `par2Filename: ""` — the "re-synced second copy" case the fix handles
  by deriving `filename + ".par2"`.
- Mirror both on the B2 side via the `URLProtocol` stub (`b2_list_file_names` →
  delete calls include the vol files).

**T4 — Import progress (bugs #14, #37).** *Extend* `PhotosImportProgressTests`.
- Multi-album: album A of 20 files completes with `filesCataloged == 20`, album B
  of 5 starts → `fraction <= 1.0` at every step. Today no test asserts the clamp.
- Property-style sweep: for a grid of `(totalFiles, filesCataloged, phase)` the
  fraction stays within `0...1` and is monotonic within an album.
- Removal phase reports the "Removing items" label with a determinate fraction.

**T5 — Pipeline cancellation semantics (bug #5).** *Extend* `AsyncPrimitivesTests`.
Full-pipeline coverage needs T-DI below, but the *shape* of the bug — a consumer
that drains its buffer instead of exiting — is testable at the primitive level:
- A consumer loop that `break`s on `Task.isCancelled` leaves the channel's
  remaining buffered items unconsumed, and a `continue`-shaped loop does not. Assert
  the observable difference (items processed after cancellation == 0).
- `AsyncChannel.cancel()` while a producer is blocked on backpressure resumes it
  *and* terminates the consumer (partly covered — extend to assert no item is
  processed post-cancel).

**T8 — Bookmark refresh (bug #7).** New `BookmarkResolverTests`.
`BookmarkResolver` methods are `nonisolated static`; bookmarks to a temp directory
work headlessly.
- `resolveAndAccess` round-trips a fresh bookmark.
- `resolveAccessAndRefresh` on a bookmark whose target was moved/recreated returns
  a usable URL and **updated bookmark data** instead of throwing.
- Corrupt bookmark data still throws (the fix must not swallow real failures).

**T11 — B2 retry coverage (bugs #10, #12).** *Extend* `B2ServiceNetworkTests`.
`withRetry` is reachable through the existing `URLProtocol` stub — no refactor.
- Stub returns 503, 503, 200 → `uploadImage` succeeds and `onAttempt` fires 3 times.
- Stub returns 401 on the second call → re-authorization happens before the retry.
- Persistent 500 → the wrapped `B2UploadError` carries filename and remote path.
- The catalog-backup path (`catalog.json`, `.sha256`, `.par2`) routes through
  `uploadImage` and therefore inherits the retry — assert via call count, since the
  regression in `154c011` was exactly "one path bypassed the wrapper."

**T13 — Catalog path resolution (bug #22).** *Extend* `PathTraversalTests`.
- `Constants.Paths.resolvedCatalogURL` honours a `catalogPath` override and expands
  `~`; falls back to `libraryURL/catalog.json` when unset (use a scoped
  `UserDefaults` suite so the test does not touch the real domain).
- `libraryURL` is symlink-resolved (guards the App Store 2.4.5(i) rejection: the UI
  must never show a container path).

---

## 5. Plan — Part C: small seams, then the tests they unlock

Each item is a narrow, behaviour-preserving refactor. Listed with the bugs it fences.

### S1 — `SyncCoordinator` hydration (bugs #21, #26, #33, #30-partial)

`hydrateSwiftData(from:)` and `hydrateSwiftDataIfStale(catalog:)` are `private`
methods on a class that also owns iCloud plumbing. Make them
`static func hydrate(catalog: Catalog, into context: ModelContext)` and
`static func isStale(catalog: Catalog, context: ModelContext) -> Bool`, keeping the
instance methods as thin call-throughs. Nothing else changes; an in-memory
`ModelContainer` then drives them.

**T9 — Hydration tests** (new `HydrationTests`):
- Empty store + populated catalog → albums and images appear (bug #21: the
  "restored successfully over an empty sidebar" case).
- Re-running hydration is an upsert: no duplicates, and local-only fields
  (`storageLocations`, `perceptualHash`, `thumbnailState`, `phAssetLocalIdentifiers`)
  survive (this invariant is asserted in `8cef649`'s message but nowhere in code).
- Store with fewer images than the catalog → `isStale` is true and hydration
  repopulates (bug #33).
- A record newer than a propagated tombstone is **not** deleted (the in-flight-import
  guard from `1da8a89`).

**T16 — Hydration cost** (same suite, guards bug #30's O(N²) regression):
- Hydrate 2,000 images and assert the number of `FetchDescriptor` executions is
  O(1) per hydration, not O(N). Assert the *call count* through a counting wrapper,
  not wall-clock time — a timing assertion would be flaky on shared runners.

### S2 — Stall/retry policy extraction (bugs #11, #13, #15, #32)

The watchdog inside `PhotosImportService.writeResource` is entangled with
`PHAssetResourceManager`, but its *decisions* are arithmetic. Extract:

```swift
nonisolated struct StallPolicy {
    static let maxAttempts = 10
    static func threshold(forAttempt n: Int) -> TimeInterval   // 1 << n
    static func secondsUntilRetry(idleFor: TimeInterval, attempt: Int) -> Int
    static func shouldSurfaceSlowBanner(elapsedForAsset: TimeInterval) -> Bool // >= 5s
}
```

**T6 — Stall policy tests**: thresholds are 1, 2, 4 … 512 across 10 attempts (#13);
the banner stays suppressed below 5 s of cumulative struggle and appears after (#15);
countdown never goes negative; attempt 10 yields `.skipped` with "iCloud download
unavailable" rather than looping.

**T7 — Idle-watchdog gate**: the same extraction makes the `importRenderedAsset`
watchdog (#32) testable — a callback that never fires must release the
process-global `AsyncSemaphore` within the idle threshold, and the fallback must
import the original resource rather than dropping the photo. Assert against a stub
"never-completes" closure driving the policy plus the real semaphore.

### S3 — Legacy catalog migration (bug #23)

Extract `migrateLegacyCatalogIfNeeded` into
`static func migrateCatalog(from legacyDir: URL, to targetDir: URL)` taking
explicit directories instead of reading `Constants.Paths` globals.

**T10 — Migration tests**: moves `catalog.json` and every `catalog.json.*` sidecar;
skips when the target already exists (never clobbers); no-ops when a `catalogPath`
override is set; leaves unrelated files alone. Also cover `StorageResolver`:
`resolveMount` returns the library URL with `securityScoped == false` for the
reserved `libraryVolumeID`, returns `nil` for an unknown volume, and
`librarySnapshot()` / `libraryMounted()` agree on the same path (the machinery that
lets the library act as a storage target — the 2.1(a) fix).

### S4 — Thumbnail cache root injection (bug #16)

`ThumbnailService` hardcodes its Application Support path. Add an `init(cacheRoot:)`
defaulting to the current value.

**T12 — Thumbnail tests**: the cache root resolves under Application Support, not
`Caches` (the exact regression in `bf00a05`); a disk cache miss triggers
regeneration from a mounted source; regeneration from an encrypted source decrypts
inside the actor; `removeThumbnails` clears both memory and disk. Use the
AVAssetWriter-generated fixture technique already proven headless-safe in
`VideoSupportTests` rather than `CIContext`, which renders all-white in CI.

### S5 — Pipeline service injection (bugs #1, #5, #9, and future pipeline work)

Already identified in TEST-PLAN as the standing "Medium effort" TODO. Introduce
protocols for the four services the coordinator drives (hash, encrypt, PAR2, upload)
and inject them. This is the largest item here and the only one I would not attempt
before Part A and Parts B/C land.

**T-DI — Pipeline orchestration tests**: cancellation mid-phase processes zero
further items and cleans staging (#5); a converted item reaches the copy stage under
its converted name (#1); a copy-stage failure does not block the independent B2
upload (`copyError` vs `error` — an invariant documented in `PipelineItem` and
tested nowhere); every stage's `defer`-finish runs on abnormal exit so downstream
consumers cannot wedge (#11).

**T15 — Replica healing (bug #24)**: `ReconciliationService.healReplicas` is an
actor method over a `VolumeSnapshot` map — testable with temp directories once
S5's B2 stub pattern is reusable. Cover: restore from a sibling volume; restore
from B2; PAR2 companions restored alongside; encrypted replicas skip hash
verification; a failure reports a reason rather than throwing away the discrepancy.

**T14 — Post-deletion push (bug #2)**: assert `pushAfterLocalChange` does not reload
the catalog from disk after a deletion — a reload resurrects stale data when the
prior save failed. Reachable once `CatalogService`'s save path is injectable the way
`SyncService`'s already is (`SyncServiceTests` uses a test-only init — follow that
precedent).

---

## 6. Deliberately out of scope

These bugs live in SwiftUI view bodies. Automating them means either XCUIAutomation
(explicitly excluded from CI in TEST-PLAN — it needs a real app launch and is
flaky headless) or extracting view logic into observable models, which is a larger
architectural change than the bug frequency justifies.

| Bug | Disposition |
| --- | --- |
| #9 `VolumeSyncSheet` copy loop | Extract the copy loop to a testable actor **if** it is touched again; otherwise manual TC-8/TC-9. |
| #17 detail-view failure states | Manual. Would become testable if the load-failure decision moved to a small enum-returning helper — worth doing opportunistically. |
| #20 Open Settings from a sheet | Manual TC-22. `@Environment(\.openSettings)` behaviour is a framework guarantee. |

The three UI-test suites already in `UITests/` cover the navigation surface for
local runs; leave them out of CI.

---

## 7. Sequencing

| Phase | Contents | Status | Bugs fenced |
| --- | --- | --- | --- |
| **0** | C1, C2, C4 — isolation-flag assertion, drift check, Xcode version assertion | **Done** | #18, #25, #35 |
| **1** | T0, T1, T3, T4, T8, T11, T13 — zero-refactor tests | **Done** | #1, #6, #7, #10, #12, #14, #22, #34, #37 |
| **2** | C3, C5, C6 — xcodebuild test job, Release archive, committed hook | **Done** | class of #35 |
| **3** | S1+T9/T16, S3+T10, T2, T5 | **Done** | #21, #23, #26, #30, #33, plus #3, #8, #5-partial |
| **4** | S2+T6/T7, S4+T12 | **Done** | #11, #13, #15, #16, #32 |
| **5** | S5+T-DI, T14, T15 | **Partial** — see §7.1 | #24 done; #2, #5, #9 outstanding |

Phases 0–2 are the ones I would insist on: they close the only gap that has
produced a *shipped, user-visible crash* and an *App Store rejection*.

### 7.1 What is still outstanding

**S5 — six-service protocol injection into `PipelinedImportCoordinator`, and the
`T-DI` orchestration tests that depend on it.** The coordinator constructs its
services as stored properties and drives eight concurrent stages over channels, a
memory budget, and a cancellation sentinel. Injection means touching every stage.
The safely-extractable part — the stage-to-stage routing — was pulled out into
`PipelinePhases` and covered exhaustively, and `ensureFileMirrored` was opened up
and covered. The rest still needs a compiler and a real run before it lands.

Still uncovered, and what T-DI would assert once injection exists:
- cancellation mid-phase processes zero further items and cleans staging (#5)
- a converted item reaches the copy stage under its converted name, end to end
  (#1 — the `PipelineItem` accessors are covered, the wiring through the stages
  is not)
- a copy-stage failure does not block the independent B2 upload (`copyError` vs
  `error`, an invariant documented in `PipelineItem` and tested nowhere)
- every stage's `defer`-finish runs on abnormal exit so downstream consumers
  cannot wedge (#11)

**T14 — post-deletion push (#2).** `pushAfterLocalChange(reloadFromDisk:)` needs
`syncService`, `backupService`, UserDefaults, and resolved volumes. Testing it
means injecting into `SyncCoordinator` the way `SyncService` already allows via
its test-only init. Not attempted.

**The three view-body bugs (#9, #17, #20)** remain out of scope for the reasons
in §6.

---

## 8. Keeping it closed

1. **Every bug-fix PR carries a failing-first regression test**, named after the
   symptom, with the commit SHA of the fix in a comment. 13 of 28 fixes shipped
   without one; that ratio is the reason this document exists.
2. **Add a PR template checklist item**: *"Regression test added, or an explicit
   note in §6-style form explaining why it is untestable."*
3. **Update the two coverage tables** in TEST-PLAN.md when a suite lands, so the
   "Not tested" rows shrink visibly.
4. **When a bug is fixed by a build setting, the guard is a CI assertion, not a
   test.** `12632f7` is the template: the product code was correct; the compiler
   flag was missing. Only C1 can see that class of defect.
