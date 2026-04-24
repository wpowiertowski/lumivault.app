# TODO — Consolidated Action Items

Collected from ARCHITECTURE-macOS.md, TEST-PLAN.md, and FIXME.md.

---

## Non-Goals / Deferred (v1)

Items explicitly scoped out of v1 but worth tracking for future development.

Source: ARCHITECTURE-macOS.md Section 11

- [ ] iOS / iPadOS companion app (catalog viewable via iCloud, no native app yet)
- [ ] Video file support

---

## Features

### Bulk Album Import & Auto-Sync

- [x] **Bulk album import** — allow selecting and importing multiple Photos albums in a single operation instead of one at a time. Queue albums and run them sequentially through the export pipeline with a combined progress/completion summary.
- [x] **Automated album sync** — detect when a previously imported album has changed in Apple Photos (new images added, images removed, edits applied) and offer to re-sync. Could use `PHChange` observation or a periodic poll comparing Photos asset count/modification dates against the catalog. Should support both manual "check for updates" and optional background monitoring.

### Near-Duplicate Handling

- [x] **Actionable near-duplicate UI** — the current NearDuplicatesView detects and displays near-duplicate pairs but offers no actions. Add per-pair resolution actions: keep both, delete one (choose which), merge (replace one with the other). Deletion should flow through DeletionService to clean up volumes and B2.
- [x] **Near-duplicate resolution during import** — currently near-duplicates are only reported in the completion screen after the fact. Allow pausing the pipeline to prompt the user when a near-duplicate is detected, or provide a post-import review step where flagged pairs can be resolved before finalizing.
- [x] **Near-duplicate threshold tuning** — expose the Hamming distance threshold (currently hardcoded at <5) as a user-configurable setting in Export Defaults. Lower values = stricter matching, higher values = more aggressive flagging.

---

## Automated Test Coverage Gaps

Items that would improve test coverage but require architectural changes.

Source: TEST-PLAN.md "Remaining Automated Test TODOs"

- [ ] **B2Service network methods** (upload, download, list, delete) — needs URLSession protocol abstraction or URLProtocol subclass for HTTP mocking. Medium effort.
- [ ] **PipelinedImportCoordinator pipeline** — channel backpressure, cancellation teardown, and phase-skipping wiring are testable in isolation. Full end-to-end pipeline still needs protocol-based service injection. Medium effort.
- [ ] **AsyncChannel / AsyncSemaphore** — new utilities with cancellation semantics (cancelAll unblocks waiters). No unit tests yet. Low effort.
- [ ] **SyncService push/pull/merge** — depends on FileManager ubiquity container + NSFileCoordinator; needs filesystem abstraction. Medium effort.
- [ ] **SyncCoordinator state machine** — orchestrates 3 services + UserDefaults + SwiftData; needs dependency injection. Medium effort.
- [ ] **ThumbnailService cache logic** — two-level cache (NSCache + disk); CIContext renders all-white at small sizes in headless CI. Low value vs manual QA.
- [ ] **PerceptualHash visual distinctness** — CIContext.render produces all-white pixels in headless test environments at 9x8 resolution. CI environment limitation.

---

## Manual Test Cases Not Automatable

Require physical hardware, external services, or inter-process interaction.

Source: TEST-PLAN.md "Manual Test Cases NOT Automated"

- TC-5 (Drag & Drop) — XCUIAutomation cannot simulate inter-process drag from Finder
- TC-8, TC-9, TC-25 (Volumes) — require physical external drive + NSOpenPanel
- TC-10, TC-19 (PAR2/Integrity) — require file corruption between UI steps
- TC-12, TC-13 (B2 Upload) — upload verification requires external B2 API checks
- TC-14 (iCloud Sync) — requires two physical devices with same iCloud account
- TC-18 (Reconciliation) — requires pre-staged volume discrepancies
- TC-23 (Edge Cases) — require external failure conditions (full disk, network drop)
- TC-24 (Tip Jar) — StoreKit sandbox interaction unreliable in UI tests

---

## Code Quality

Nothing pending — IntegrityServiceTests was removed along with IntegrityService in PR 2 of the cleanup plan.
