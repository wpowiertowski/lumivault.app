import SwiftUI
import SwiftData

struct ReconciliationView: View {
    @Query private var images: [ImageRecord]
    @Query private var volumes: [VolumeRecord]
    @AppStorage("b2Enabled") private var b2Enabled = false

    @State private var progress = ReconciliationProgress()
    @State private var report: ReconciliationReport?
    @State private var isScanning = false
    @State private var verifyHashes = false

    private let reconciliationService = ReconciliationService()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let report {
                resultsList(report)
            } else if isScanning {
                scanningView
            } else {
                idleView
            }

            Divider()

            // Bottom bar
            HStack {
                if let report {
                    Text("\(report.discrepancies.count) issues found")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("Verify file hashes", isOn: $verifyHashes)
                        .font(Constants.Design.monoCaption)
                        .toggleStyle(.checkbox)
                        .disabled(isScanning)
                        .help("Compute SHA-256 of every file on volumes to detect corruption. Slower but thorough.")
                        .accessibilityIdentifier("integrity.verifyHashes")
                }
                Spacer()
                Button(isScanning ? "Scanning..." : "Scan") { startScan() }
                    .disabled(isScanning || images.isEmpty)
                    .accessibilityIdentifier("integrity.scan")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.shield")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Storage Integrity")
                .font(Constants.Design.monoHeadline)
                .foregroundStyle(.secondary)
            Text("Scan to compare your catalog against\nexternal volumes and B2 cloud storage.")
                .font(Constants.Design.monoCaption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Scanning

    private var scanningView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView(value: progress.fraction)
                .padding(.horizontal, 40)
            Text(progress.phase.rawValue)
                .font(Constants.Design.monoBody)
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                StatLabel(label: "Scanned", value: progress.processedItems)
                StatLabel(label: "Issues", value: progress.discrepanciesFound)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Results

    private func resultsList(_ report: ReconciliationReport) -> some View {
        Group {
            if report.discrepancies.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.green)
                    Text("All clear")
                        .font(Constants.Design.monoHeadline)
                        .foregroundStyle(.secondary)
                    Text("No discrepancies found across\n\(report.scannedImages) images, \(report.scannedVolumes) volumes\(report.scannedB2Files > 0 ? ", \(report.scannedB2Files) B2 files" : "").")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(groupedDiscrepancies(report.discrepancies), id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.items) { item in
                                DiscrepancyRow(discrepancy: item)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func startScan() {
        isScanning = true
        report = nil
        progress = ReconciliationProgress()

        let snapshots = images.map { image in
            ImageSnapshot(
                sha256: image.sha256,
                filename: image.filename,
                b2FileId: image.b2FileId,
                storageLocations: image.storageLocations,
                albumPath: image.album.map { "\($0.year)/\($0.month)/\($0.day)/\($0.name)" } ?? ""
            )
        }

        let volumeSnapshots: [VolumeSnapshot] = volumes.compactMap { volume in
            guard let url = try? BookmarkResolver.resolveAndAccess(volume.bookmarkData) else { return nil }
            return VolumeSnapshot(volumeID: volume.volumeID, label: volume.label, mountURL: url)
        }

        var b2Creds: B2Credentials?
        if b2Enabled,
           let data = UserDefaults.standard.data(forKey: B2Credentials.defaultsKey),
           let creds = try? JSONDecoder().decode(B2Credentials.self, from: data) {
            b2Creds = creds
        }

        let progress = self.progress
        let verifyHashes = self.verifyHashes

        Task { @MainActor in
            let result = await reconciliationService.reconcile(
                snapshots: snapshots,
                volumes: volumeSnapshots,
                b2Credentials: b2Creds,
                verifyHashes: verifyHashes,
                progress: progress
            )

            // Stop accessing security-scoped resources
            for vs in volumeSnapshots {
                vs.mountURL.stopAccessingSecurityScopedResource()
            }

            self.report = result
            self.isScanning = false
        }
    }

    // MARK: - Grouping

    private struct DiscrepancyGroup {
        let title: String
        let items: [Discrepancy]
    }

    private func groupedDiscrepancies(_ discrepancies: [Discrepancy]) -> [DiscrepancyGroup] {
        var dangling: [Discrepancy] = []
        var orphansVolume: [Discrepancy] = []
        var danglingB2: [Discrepancy] = []
        var orphansB2: [Discrepancy] = []
        var missing: [Discrepancy] = []
        var hashMismatches: [Discrepancy] = []

        for d in discrepancies {
            switch d.kind {
            case .danglingLocation: dangling.append(d)
            case .orphanOnVolume: orphansVolume.append(d)
            case .danglingB2FileId: danglingB2.append(d)
            case .orphanInB2: orphansB2.append(d)
            case .missingFromVolume: missing.append(d)
            case .hashMismatch: hashMismatches.append(d)
            }
        }

        var groups: [DiscrepancyGroup] = []
        if !hashMismatches.isEmpty { groups.append(.init(title: "Corrupted Files", items: hashMismatches)) }
        if !dangling.isEmpty { groups.append(.init(title: "Missing from Volume", items: dangling)) }
        if !orphansVolume.isEmpty { groups.append(.init(title: "Untracked on Volume", items: orphansVolume)) }
        if !danglingB2.isEmpty { groups.append(.init(title: "Missing from B2", items: danglingB2)) }
        if !orphansB2.isEmpty { groups.append(.init(title: "Untracked in B2", items: orphansB2)) }
        if !missing.isEmpty { groups.append(.init(title: "Not Mirrored", items: missing)) }
        return groups
    }
}

// MARK: - Subviews

private struct DiscrepancyRow: View {
    let discrepancy: Discrepancy

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(discrepancy.filename)
                    .font(Constants.Design.monoBody)
                    .lineLimit(1)
                Text(description)
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var iconName: String {
        switch discrepancy.kind {
        case .danglingLocation, .danglingB2FileId: "exclamationmark.triangle"
        case .orphanOnVolume, .orphanInB2: "questionmark.circle"
        case .missingFromVolume: "arrow.right.circle"
        case .hashMismatch: "xmark.shield"
        }
    }

    private var iconColor: Color {
        switch discrepancy.kind {
        case .danglingLocation, .danglingB2FileId: .orange
        case .orphanOnVolume, .orphanInB2: .yellow
        case .missingFromVolume: .blue
        case .hashMismatch: .red
        }
    }

    private var description: String {
        switch discrepancy.kind {
        case .danglingLocation(let vid): "Expected on volume \(vid) but not found"
        case .orphanOnVolume(let vid, let path): "Found on \(vid) at \(path), not in catalog"
        case .danglingB2FileId: "B2 file ID recorded but file not found in bucket"
        case .orphanInB2(_, let name): "In B2 as \(name), not tracked in catalog"
        case .missingFromVolume(let vid): "Not mirrored to volume \(vid)"
        case .hashMismatch(let vid, let expected, let actual): "Hash mismatch on \(vid): expected \(String(expected.prefix(8)))… got \(String(actual.prefix(8)))…"
        }
    }
}

private struct StatLabel: View {
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
