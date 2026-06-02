import SwiftUI
import SwiftData

struct IntegritySheet: View {
    let title: String
    let images: [ImageRecord]
    @Query private var volumes: [VolumeRecord]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @AppStorage("b2Enabled") private var b2Enabled = false

    @State private var phase: IntegrityPhase = .scanning
    @State private var progress = ReconciliationProgress()
    @State private var repairResults: [RepairResult] = []
    @State private var healResults: [HealResult] = []
    @State private var report: ReconciliationReport?
    @State private var showingDetails = false
    @State private var isHealing = false

    private let reconciliationService = ReconciliationService()

    private var volumeLabelMap: [String: String] {
        Dictionary(uniqueKeysWithValues: volumes.map { ($0.volumeID, $0.label) })
    }

    /// Discrepancies the heal pass can act on: a file missing from a volume that
    /// may still exist on a sibling volume or in B2.
    private var healableCount: Int {
        report?.discrepancies.filter {
            if case .danglingLocation = $0.kind { return true }
            return false
        }.count ?? 0
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(Constants.Design.accentColor)
                Text("Verifying \(title)")
                    .font(Constants.Design.monoHeadline)
                    .lineLimit(1)
            }
            .padding(.top)

            Divider()

            // Content
            switch phase {
            case .scanning:
                scanningView
            case .complete:
                completeView
            }

            Divider()

            // Actions
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(phase == .scanning || isHealing)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(width: 400, height: 340)
        .sheet(isPresented: $showingDetails) {
            if let report {
                IntegrityDetailsSheet(
                    discrepancies: report.discrepancies,
                    repairResults: repairResults,
                    volumeLabels: volumeLabelMap
                )
            }
        }
        .task { await runVerification() }
    }

    // MARK: - Views

    private var scanningView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView(value: progress.fraction)
                .padding(.horizontal, 32)
            Text(progress.phase.rawValue)
                .font(Constants.Design.monoBody)
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                IntegrityStat(label: "Checked", value: progress.processedItems)
                IntegrityStat(label: "Issues", value: progress.discrepanciesFound)
            }
            Spacer()
        }
    }

    private var completeView: some View {
        Group {
            if let report, report.discrepancies.isEmpty && repairResults.isEmpty && healResults.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.green)
                    Text("All clear")
                        .font(Constants.Design.monoHeadline)
                        .foregroundStyle(.secondary)
                    Text("No corruption detected across\n\(report.scannedImages) images, \(report.scannedVolumes) volumes.")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if !repairResults.isEmpty || !healResults.isEmpty {
                VStack(spacing: 0) {
                    List {
                        if !repairResults.isEmpty {
                            Section("Repairs") {
                                ForEach(repairResults, id: \.sha256) { result in
                                    RepairResultRow(result: result)
                                }
                            }
                        }
                        if !healResults.isEmpty {
                            Section("Restored Replicas") {
                                ForEach(Array(healResults.enumerated()), id: \.offset) { _, result in
                                    HealResultRow(result: result, volumeLabels: volumeLabelMap)
                                }
                            }
                        }
                    }
                    completeFooter
                }
            } else if report != nil {
                // Discrepancies found but no repair/heal results yet (non-hash issues)
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                    Text("\(report?.discrepancies.count ?? 0) issues found")
                        .font(Constants.Design.monoHeadline)
                        .foregroundStyle(.secondary)
                    completeFooter
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Footer shown after a scan: optional "restore missing replicas" action plus
    /// a details link. The restore button is opt-in — it only acts when tapped.
    @ViewBuilder
    private var completeFooter: some View {
        HStack(spacing: 12) {
            if healableCount > 0 {
                Button(isHealing ? "Restoring..." : "Restore Missing Replicas") {
                    Task { await runHeal() }
                }
                .font(Constants.Design.monoCaption)
                .disabled(isHealing)
                .accessibilityIdentifier("integrity.healMissing")
            }
            if let report, !report.discrepancies.isEmpty {
                Button("Show Details") { showingDetails = true }
                    .font(Constants.Design.monoCaption)
                    .disabled(isHealing)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Verification

    private func makeSnapshots() -> [ImageSnapshot] {
        images.map { image in
            ImageSnapshot(
                sha256: image.sha256,
                filename: image.filename,
                par2Filename: image.par2Filename,
                b2FileId: image.b2FileId,
                storageLocations: image.storageLocations,
                albumPath: image.album.map { "\($0.year)/\($0.month)/\($0.day)/\($0.name)" } ?? "",
                isEncrypted: image.isEncrypted
            )
        }
    }

    private func resolveVolumeSnapshots() -> [VolumeSnapshot] {
        volumes.compactMap { volume in
            guard let url = try? BookmarkResolver.resolveAndAccess(volume.bookmarkData) else { return nil }
            return VolumeSnapshot(volumeID: volume.volumeID, label: volume.label, mountURL: url)
        }
    }

    private func runVerification() async {
        let snapshots = makeSnapshots()
        let volumeSnapshots = resolveVolumeSnapshots()

        // Per-album/-image verify stays scoped to volumes: passing B2 credentials
        // here would make `diffB2` treat every B2 object outside this subset as an
        // orphan. B2 is still usable as a heal *source* via `runHeal()`.
        let result = await reconciliationService.reconcile(
            snapshots: snapshots,
            volumes: volumeSnapshots,
            b2Credentials: nil,
            verifyHashes: true,
            scanOrphans: false,
            progress: progress
        )

        // Auto-repair any hash mismatches
        let repairs = await reconciliationService.repairCorruptedFiles(
            discrepancies: result.discrepancies,
            snapshots: snapshots,
            volumes: volumeSnapshots,
            progress: progress
        )

        for vs in volumeSnapshots {
            vs.mountURL.stopAccessingSecurityScopedResource()
        }

        self.repairResults = repairs
        self.report = result
        self.phase = .complete
    }

    /// Opt-in: restore files flagged missing from a volume by copying them back
    /// from a healthy sibling volume or from B2, then re-verify.
    private func runHeal() async {
        guard let report else { return }
        isHealing = true
        defer { isHealing = false }

        let snapshots = makeSnapshots()
        let volumeSnapshots = resolveVolumeSnapshots()
        let b2Creds = b2Enabled ? B2Credentials.load() : nil

        let heals = await reconciliationService.healReplicas(
            discrepancies: report.discrepancies,
            snapshots: snapshots,
            volumes: volumeSnapshots,
            b2Credentials: b2Creds,
            progress: progress
        )

        // Persist any new B2 fileIds (re-uploads) to SwiftData + catalog.json.
        for heal in heals {
            guard case .restoredToB2(let newFileId, _) = heal.outcome else { continue }
            if let record = images.first(where: { $0.sha256 == heal.sha256 }) {
                record.b2FileId = newFileId
            }
            await syncCoordinator.updateImageB2FileId(sha256: heal.sha256, b2FileId: newFileId)
        }
        try? modelContext.save()

        // Re-verify so the report reflects the restored state.
        let result = await reconciliationService.reconcile(
            snapshots: makeSnapshots(),
            volumes: volumeSnapshots,
            b2Credentials: nil,
            verifyHashes: true,
            scanOrphans: false,
            progress: progress
        )

        for vs in volumeSnapshots {
            vs.mountURL.stopAccessingSecurityScopedResource()
        }

        self.healResults = heals
        self.report = result
    }

    // MARK: - Types

    private enum IntegrityPhase {
        case scanning, complete
    }
}

// MARK: - Details Sheet

private struct IntegrityDetailsSheet: View {
    let discrepancies: [Discrepancy]
    let repairResults: [RepairResult]
    let volumeLabels: [String: String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(Constants.Design.accentColor)
                Text("\(discrepancies.count) Issues")
                    .font(Constants.Design.monoHeadline)
            }
            .padding(.top)

            Divider()

            List {
                ForEach(discrepancies) { discrepancy in
                    DiscrepancyRow(
                        discrepancy: discrepancy,
                        repairResult: repairResults.first { $0.sha256 == discrepancy.sha256 },
                        volumeLabels: volumeLabels
                    )
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(width: 500, height: 400)
    }
}

private struct IntegrityStat: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(Constants.Design.monoTitle3)
            Text(label)
                .font(Constants.Design.monoCaption)
                .foregroundStyle(.secondary)
        }
    }
}
