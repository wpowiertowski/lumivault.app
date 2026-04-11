import SwiftUI
import SwiftData

struct ReconciliationView: View {
    @Query private var images: [ImageRecord]
    @Query private var volumes: [VolumeRecord]
    @AppStorage("b2Enabled") private var b2Enabled = false

    @State private var progress = ReconciliationProgress()
    @State private var report: ReconciliationReport?
    @State private var repairResults: [RepairResult] = []
    @State private var isScanning = false
    @State private var verifyHashes = false
    @State private var repairCorrupted = false
    @State private var showingB2SyncSheet = false
    @State private var showingVolumeSyncSheet = false
    @State private var selectedVolume: VolumeRecord?

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

            // Sync actions
            HStack(spacing: 12) {
                if b2Enabled && hasB2Credentials {
                    Button("Sync Volumes to B2...") { showingB2SyncSheet = true }
                        .accessibilityIdentifier("integrity.syncToB2")
                }
                if !volumes.isEmpty {
                    Menu("Sync to Volume...") {
                        ForEach(volumes, id: \.persistentModelID) { volume in
                            Button(volume.label) {
                                selectedVolume = volume
                                showingVolumeSyncSheet = true
                            }
                        }
                    }
                    .accessibilityIdentifier("integrity.syncToVolume")
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            // Bottom bar
            HStack {
                if let report {
                    Text(statusText(report))
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("Verify file hashes", isOn: $verifyHashes)
                        .font(Constants.Design.monoCaption)
                        .toggleStyle(.checkbox)
                        .disabled(isScanning || repairCorrupted)
                        .help("Compute SHA-256 of every file on volumes to detect corruption. Slower but thorough.")
                        .accessibilityIdentifier("integrity.verifyHashes")
                    Toggle("Auto-repair", isOn: $repairCorrupted)
                        .font(Constants.Design.monoCaption)
                        .toggleStyle(.checkbox)
                        .disabled(isScanning)
                        .help("Automatically repair corrupted files by copying from a healthy volume or using PAR2 recovery data.")
                        .accessibilityIdentifier("integrity.repairCorrupted")
                        .onChange(of: repairCorrupted) { _, newValue in
                            if newValue { verifyHashes = true }
                        }
                }
                Spacer()
                Button(isScanning ? "Scanning..." : "Scan") { startScan() }
                    .disabled(isScanning || images.isEmpty)
                    .accessibilityIdentifier("integrity.scan")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showingB2SyncSheet) {
            if let credentials = loadB2Credentials() {
                B2SyncSheet(credentials: credentials)
            }
        }
        .sheet(isPresented: $showingVolumeSyncSheet) {
            if let volume = selectedVolume {
                VolumeSyncSheet(volume: volume)
            }
        }
    }

    private var hasB2Credentials: Bool {
        UserDefaults.standard.data(forKey: B2Credentials.defaultsKey) != nil
    }

    private func loadB2Credentials() -> B2Credentials? {
        guard let data = UserDefaults.standard.data(forKey: B2Credentials.defaultsKey),
              let creds = try? JSONDecoder().decode(B2Credentials.self, from: data) else { return nil }
        return creds
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
            if report.discrepancies.isEmpty && repairResults.isEmpty {
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
                    if !repairResults.isEmpty {
                        Section("Repairs") {
                            ForEach(repairResults, id: \.sha256) { result in
                                RepairResultRow(result: result)
                            }
                        }
                    }
                    ForEach(groupedDiscrepancies(report.discrepancies), id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.items) { item in
                                DiscrepancyRow(discrepancy: item, repairResult: repairResultFor(item))
                            }
                        }
                    }
                }
            }
        }
    }

    private func statusText(_ report: ReconciliationReport) -> String {
        if repairResults.isEmpty {
            return "\(report.discrepancies.count) issues found"
        }
        let repaired = repairResults.filter {
            switch $0.outcome {
            case .copiedFromVolume, .repairedViaPAR2: true
            case .failed: false
            }
        }.count
        let failed = repairResults.count - repaired
        var parts = ["\(report.discrepancies.count) issues found"]
        if repaired > 0 { parts.append("\(repaired) repaired") }
        if failed > 0 { parts.append("\(failed) unrecoverable") }
        return parts.joined(separator: ", ")
    }

    private func repairResultFor(_ discrepancy: Discrepancy) -> RepairResult? {
        guard case .hashMismatch(let vid, _, _) = discrepancy.kind else { return nil }
        return repairResults.first { $0.sha256 == discrepancy.sha256 && $0.volumeID == vid }
    }

    // MARK: - Actions

    private func startScan() {
        isScanning = true
        report = nil
        repairResults = []
        progress = ReconciliationProgress()

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

        var b2Creds: B2Credentials?
        if b2Enabled,
           let data = UserDefaults.standard.data(forKey: B2Credentials.defaultsKey),
           let creds = try? JSONDecoder().decode(B2Credentials.self, from: data) {
            b2Creds = creds
        }

        let progress = self.progress
        let verifyHashes = self.verifyHashes
        let shouldRepair = self.repairCorrupted

        Task { @MainActor in
            let result = await reconciliationService.reconcile(
                snapshots: snapshots,
                volumes: volumeSnapshots,
                b2Credentials: b2Creds,
                verifyHashes: verifyHashes,
                progress: progress
            )

            // Repair corrupted files if enabled
            if shouldRepair {
                let repairs = await reconciliationService.repairCorruptedFiles(
                    discrepancies: result.discrepancies,
                    snapshots: snapshots,
                    volumes: volumeSnapshots,
                    progress: progress
                )
                self.repairResults = repairs
            }

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
    var repairResult: RepairResult? = nil

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
                if let repair = repairResult {
                    Text(repairDescription(repair))
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(repairColor(repair))
                        .lineLimit(1)
                }
            }
        }
    }

    private var iconName: String {
        if let repair = repairResult {
            switch repair.outcome {
            case .copiedFromVolume, .repairedViaPAR2: return "checkmark.shield"
            case .failed: return "xmark.shield"
            }
        }
        switch discrepancy.kind {
        case .danglingLocation, .danglingB2FileId: return "exclamationmark.triangle"
        case .orphanOnVolume, .orphanInB2: return "questionmark.circle"
        case .missingFromVolume: return "arrow.right.circle"
        case .hashMismatch: return "xmark.shield"
        }
    }

    private var iconColor: Color {
        if let repair = repairResult {
            switch repair.outcome {
            case .copiedFromVolume, .repairedViaPAR2: return .green
            case .failed: return .red
            }
        }
        switch discrepancy.kind {
        case .danglingLocation, .danglingB2FileId: return .orange
        case .orphanOnVolume, .orphanInB2: return .yellow
        case .missingFromVolume: return .blue
        case .hashMismatch: return .red
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

    private func repairDescription(_ result: RepairResult) -> String {
        switch result.outcome {
        case .copiedFromVolume(let vid): "Repaired — copied from \(vid)"
        case .repairedViaPAR2: "Repaired — PAR2 recovery"
        case .failed(let reason): "Repair failed — \(reason)"
        }
    }

    private func repairColor(_ result: RepairResult) -> Color {
        switch result.outcome {
        case .copiedFromVolume, .repairedViaPAR2: .green
        case .failed: .red
        }
    }
}

struct RepairResultRow: View {
    let result: RepairResult

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.filename)
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
        switch result.outcome {
        case .copiedFromVolume, .repairedViaPAR2: "checkmark.shield"
        case .failed: "xmark.shield"
        }
    }

    private var iconColor: Color {
        switch result.outcome {
        case .copiedFromVolume, .repairedViaPAR2: .green
        case .failed: .red
        }
    }

    private var description: String {
        switch result.outcome {
        case .copiedFromVolume(let vid): "Repaired — copied from \(vid)"
        case .repairedViaPAR2: "Repaired — PAR2 recovery"
        case .failed(let reason): "Repair failed — \(reason)"
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
