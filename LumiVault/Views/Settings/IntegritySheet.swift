import SwiftUI
import SwiftData

struct IntegritySheet: View {
    let title: String
    let images: [ImageRecord]
    @Query private var volumes: [VolumeRecord]
    @Environment(\.dismiss) private var dismiss

    @State private var phase: IntegrityPhase = .scanning
    @State private var progress = ReconciliationProgress()
    @State private var repairResults: [RepairResult] = []
    @State private var report: ReconciliationReport?
    @State private var showingDetails = false

    private let reconciliationService = ReconciliationService()

    private var volumeLabelMap: [String: String] {
        Dictionary(uniqueKeysWithValues: volumes.map { ($0.volumeID, $0.label) })
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
                    .disabled(phase == .scanning)
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
            if let report, report.discrepancies.isEmpty && repairResults.isEmpty {
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
            } else if !repairResults.isEmpty {
                VStack(spacing: 0) {
                    List {
                        ForEach(repairResults, id: \.sha256) { result in
                            RepairResultRow(result: result)
                        }
                    }
                    if let report, !report.discrepancies.isEmpty {
                        Button("Show Details") {
                            showingDetails = true
                        }
                        .font(Constants.Design.monoCaption)
                        .padding(.top, 8)
                    }
                }
            } else if let report {
                // Discrepancies found but no repair results (non-hash issues)
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                    Text("\(report.discrepancies.count) issues found")
                        .font(Constants.Design.monoHeadline)
                        .foregroundStyle(.secondary)
                    Button("Show Details") {
                        showingDetails = true
                    }
                    .font(Constants.Design.monoCaption)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Verification

    private func runVerification() async {
        let snapshots = images.map { image in
            ImageSnapshot(
                sha256: image.sha256,
                filename: image.filename,
                par2Filename: image.par2Filename,
                b2FileId: image.b2FileId,
                storageLocations: image.storageLocations,
                albumPath: image.album.map { "\($0.year)/\($0.month)/\($0.day)/\($0.name)" } ?? ""
            )
        }

        let volumeSnapshots: [VolumeSnapshot] = volumes.compactMap { volume in
            guard let url = try? BookmarkResolver.resolveAndAccess(volume.bookmarkData) else { return nil }
            return VolumeSnapshot(volumeID: volume.volumeID, label: volume.label, mountURL: url)
        }

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
