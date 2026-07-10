import SwiftUI
import SwiftData

struct ReconciliationView: View {
    @Query private var images: [ImageRecord]
    @Query private var volumes: [VolumeRecord]
    @AppStorage("b2Enabled") private var b2Enabled = false
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncCoordinator.self) private var syncCoordinator

    @State private var progress = ReconciliationProgress()
    @State private var report: ReconciliationReport?
    @State private var repairResults: [RepairResult] = []
    @State private var healResults: [HealResult] = []
    @State private var isScanning = false
    @State private var verifyHashes = false
    @State private var repairCorrupted = false
    @State private var healMissing = false
    @State private var showingB2SyncSheet = false
    @State private var showingVolumeSyncSheet = false
    @State private var selectedVolume: VolumeRecord?

    private let reconciliationService = ReconciliationService()

    private var volumeLabelMap: [String: String] {
        Dictionary(uniqueKeysWithValues: volumes.map { ($0.volumeID, $0.label) })
    }

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
                    Toggle("Heal missing replicas", isOn: $healMissing)
                        .font(Constants.Design.monoCaption)
                        .toggleStyle(.checkbox)
                        .disabled(isScanning)
                        .help("When a file is missing from one storage but present in another (another volume or B2), copy it back so every storage target holds it.")
                        .accessibilityIdentifier("integrity.healMissing")
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
        B2Credentials.isConfigured
    }

    private func loadB2Credentials() -> B2Credentials? {
        B2Credentials.load()
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
            if report.discrepancies.isEmpty && repairResults.isEmpty && healResults.isEmpty {
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
                    if !healResults.isEmpty {
                        Section("Restored Replicas") {
                            ForEach(Array(healResults.enumerated()), id: \.offset) { _, result in
                                HealResultRow(result: result, volumeLabels: volumeLabelMap)
                            }
                        }
                    }
                    ForEach(groupedDiscrepancies(report.discrepancies), id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.items) { item in
                                DiscrepancyRow(discrepancy: item, repairResult: repairResultFor(item), volumeLabels: volumeLabelMap)
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
        healResults = []
        progress = ReconciliationProgress()

        let snapshots = images.map { image in
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

        let volumeSnapshots: [VolumeSnapshot] = volumes.compactMap { volume in
            guard let url = try? BookmarkResolver.resolveAndAccess(volume.bookmarkData) else { return nil }
            return VolumeSnapshot(volumeID: volume.volumeID, label: volume.label, mountURL: url)
        }
        // Include the local library as a first-class reconcile/repair/heal target.
        let allTargets = [StorageResolver.librarySnapshot()] + volumeSnapshots

        let b2Creds = b2Enabled ? B2Credentials.load() : nil

        let progress = self.progress
        let verifyHashes = self.verifyHashes
        let shouldRepair = self.repairCorrupted
        let shouldHeal = self.healMissing

        Task { @MainActor in
            var result = await reconciliationService.reconcile(
                snapshots: snapshots,
                volumes: allTargets,
                b2Credentials: b2Creds,
                verifyHashes: verifyHashes,
                progress: progress
            )

            // Repair corrupted files if enabled
            if shouldRepair {
                let repairs = await reconciliationService.repairCorruptedFiles(
                    discrepancies: result.discrepancies,
                    snapshots: snapshots,
                    volumes: allTargets,
                    progress: progress
                )
                self.repairResults = repairs
            }

            // Heal missing replicas: fan a file present in one storage back out to
            // any storage that's missing it, then re-scan so the report reflects the
            // restored state.
            if shouldHeal {
                let heals = await reconciliationService.healReplicas(
                    discrepancies: result.discrepancies,
                    snapshots: snapshots,
                    volumes: allTargets,
                    b2Credentials: b2Creds,
                    progress: progress
                )
                self.healResults = heals
                await applyB2WriteBacks(heals)

                if heals.contains(where: { if case .failed = $0.outcome { return false } else { return true } }) {
                    result = await reconciliationService.reconcile(
                        snapshots: rebuildSnapshots(),
                        volumes: allTargets,
                        b2Credentials: b2Creds,
                        verifyHashes: verifyHashes,
                        progress: progress
                    )
                }
            }

            // Stop accessing security-scoped resources
            for vs in volumeSnapshots {
                vs.mountURL.stopAccessingSecurityScopedResource()
            }

            self.report = result
            self.isScanning = false
        }
    }

    /// Persist new B2 fileIds produced by the heal pass to both SwiftData and the
    /// shared catalog.json so a subsequent scan doesn't re-flag them as dangling.
    private func applyB2WriteBacks(_ heals: [HealResult]) async {
        for heal in heals {
            guard case .restoredToB2(let newFileId, _) = heal.outcome else { continue }
            if let record = images.first(where: { $0.sha256 == heal.sha256 }) {
                record.b2FileId = newFileId
            }
            await syncCoordinator.updateImageB2FileId(sha256: heal.sha256, b2FileId: newFileId)
        }
        try? modelContext.save()
    }

    /// Rebuild image snapshots from the current SwiftData state (post write-back)
    /// for the confirmation re-scan after healing.
    private func rebuildSnapshots() -> [ImageSnapshot] {
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

/// Full-detail popover shown when an integrity row is double-clicked. Rows truncate
/// their text to one line, and the Settings window is fixed-size, so this is the
/// only place long paths/hashes are readable (and selectable) in full.
struct IssueDetailPopover: View {
    let title: String
    let fields: [(label: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Constants.Design.monoHeadline)
                .textSelection(.enabled)
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label.uppercased())
                        .font(Constants.Design.monoCaption2)
                        .foregroundStyle(.tertiary)
                    Text(field.value)
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
    }
}

struct DiscrepancyRow: View {
    let discrepancy: Discrepancy
    var repairResult: RepairResult? = nil
    var volumeLabels: [String: String] = [:]
    @State private var showingDetails = false

    private func volumeName(_ vid: String) -> String {
        volumeLabels[vid] ?? vid
    }

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
        .help(description)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { showingDetails = true }
        .popover(isPresented: $showingDetails) {
            IssueDetailPopover(title: discrepancy.filename, fields: detailFields)
        }
    }

    private var detailFields: [(label: String, value: String)] {
        var fields: [(String, String)] = [("Issue", detailDescription)]
        if case .orphanOnVolume(_, let path) = discrepancy.kind {
            fields.append(("Path on volume", path))
        }
        if !discrepancy.sha256.isEmpty {
            fields.append(("SHA-256", discrepancy.sha256))
        }
        if let repair = repairResult {
            fields.append(("Repair", repairDescription(repair)))
        }
        return fields
    }

    /// Like `description`, but without abbreviations — full hashes for mismatches.
    private var detailDescription: String {
        if case .hashMismatch(let vid, let expected, let actual) = discrepancy.kind {
            return "Hash mismatch on \(volumeName(vid)).\nExpected: \(expected)\nActual: \(actual)"
        }
        return description
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
        case .danglingLocation(let vid): "Expected on \(volumeName(vid)) but not found"
        case .orphanOnVolume(let vid, let path): "Found on \(volumeName(vid)) at \(path), not in catalog"
        case .danglingB2FileId: "B2 file ID recorded but file not found in bucket"
        case .orphanInB2(_, let name): "In B2 as \(name), not tracked in catalog"
        case .missingFromVolume(let vid): "Not mirrored to \(volumeName(vid))"
        case .hashMismatch(let vid, let expected, let actual): "Hash mismatch on \(volumeName(vid)): expected \(String(expected.prefix(8)))… got \(String(actual.prefix(8)))…"
        }
    }

    private func repairDescription(_ result: RepairResult) -> String {
        switch result.outcome {
        case .copiedFromVolume(let vid): "Repaired — copied from \(volumeName(vid))"
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
    @State private var showingDetails = false

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
        .help(description)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { showingDetails = true }
        .popover(isPresented: $showingDetails) {
            IssueDetailPopover(title: result.filename, fields: [
                ("Result", description),
                ("SHA-256", result.sha256),
            ])
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

struct HealResultRow: View {
    let result: HealResult
    var volumeLabels: [String: String] = [:]
    @State private var showingDetails = false

    private func volumeName(_ vid: String) -> String { volumeLabels[vid] ?? vid }

    private func sourceName(_ source: HealResult.Source) -> String {
        switch source {
        case .volume(let vid): volumeName(vid)
        case .b2: "B2"
        }
    }

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
        .help(description)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { showingDetails = true }
        .popover(isPresented: $showingDetails) {
            IssueDetailPopover(title: result.filename, fields: [
                ("Result", description),
                ("SHA-256", result.sha256),
            ])
        }
    }

    private var iconName: String {
        switch result.outcome {
        case .restoredToVolume, .restoredToB2: "checkmark.shield"
        case .failed: "xmark.shield"
        }
    }

    private var iconColor: Color {
        switch result.outcome {
        case .restoredToVolume, .restoredToB2: .green
        case .failed: .red
        }
    }

    private var description: String {
        switch result.outcome {
        case .restoredToVolume(let vid, let source): "Restored to \(volumeName(vid)) from \(sourceName(source))"
        case .restoredToB2(_, let source): "Re-uploaded to B2 from \(sourceName(source))"
        case .failed(let reason): "Heal failed — \(reason)"
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
