import SwiftUI
import SwiftData

struct PhotosImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.modelContext) private var modelContext
    @State private var step: ImportStep = .pickAlbum
    @State private var selectedAlbumIds: Set<String> = []
    @State private var selectedAlbumTitle: String = ""
    @State private var settings = ImportSettings(
        albumName: "",
        year: "",
        month: "",
        day: ""
    )
    @State private var progress = PhotosImportProgress()
    @State private var isImporting = false
    @State private var importTask: Task<Void, Never>?
    @State private var currentImportAlbumIndex: Int = 0
    @State private var totalImportAlbums: Int = 0
    @State private var currentImportAlbumName: String = ""
    @State private var showGamesOffer = false
    @State private var showingGames = false
    @State private var gameProgress = GameProgressMirror()
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @Environment(PhotosLibraryMonitor.self) private var photosMonitor
    @Environment(\.encryptionService) private var encryptionService
    @Query private var volumes: [VolumeRecord]
    @State private var catalogAlbumCounts: [String: Int] = [:]
    /// Every Photos asset id tracked anywhere in the catalog. The picker
    /// intersects each album's live asset ids with this to compute sync status
    /// correctly even when duplicates dedup across albums.
    @State private var globalTrackedIds: Set<String> = []
    @State private var pendingImports: [PendingAlbumImport] = []
    @State private var isComputingDates = false
    @State private var storageWarningAcknowledged = false

    private var isMultiAlbum: Bool { selectedAlbumIds.count > 1 }

    /// Whether any real archive destination (connected volume or B2) is available.
    /// When false, the user must acknowledge the library-fallback warning before importing.
    private var hasStorage: Bool {
        if B2Credentials.isConfigured { return true }
        return volumes.contains { volume in
            (try? BookmarkResolver.resolveAndAccess(volume.bookmarkData)).map {
                $0.stopAccessingSecurityScopedResource()
                return true
            } ?? false
        }
    }

    private var showingStorageWarning: Bool {
        step == .pickAlbum && !hasStorage && !storageWarningAcknowledged
    }

    private var visibleSteps: [ImportStep] {
        isMultiAlbum
            ? [.pickAlbum, .configure, .confirmDates, .importing, .complete]
            : [.pickAlbum, .configure, .importing, .complete]
    }

    private let catalogService = CatalogService()

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            StepIndicator(current: step, steps: visibleSteps)
                .padding()

            Divider()

            // Content
            Group {
                switch step {
                case .pickAlbum:
                    if showingStorageWarning {
                        storageWarningView
                    } else {
                        albumPickerStep
                    }
                case .configure:
                    configureStep
                case .confirmDates:
                    confirmDatesStep
                case .importing:
                    if showingGames {
                        GameStepView(progress: gameProgress) {
                            showingGames = false
                        }
                    } else {
                        importingStep
                    }
                case .complete:
                    completeStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation buttons
            HStack {
                Button("Cancel") {
                    importTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("import.cancel")

                Spacer()

                switch step {
                case .pickAlbum:
                    if !showingStorageWarning {
                        Button("Next") { goToSettings() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(selectedAlbumIds.isEmpty)
                            .accessibilityIdentifier("import.next")
                    }

                case .configure:
                    Button("Back") { step = .pickAlbum }
                        .accessibilityIdentifier("import.back")
                    if isMultiAlbum {
                        Button("Next") { step = .confirmDates }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("import.next")
                    } else {
                        Button("Start Import") { startImport() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(settings.albumName.isEmpty)
                            .accessibilityIdentifier("import.start")
                    }

                case .confirmDates:
                    Button("Back") { step = .configure }
                        .accessibilityIdentifier("import.back")
                    Button("Start Import") { startImport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isComputingDates || pendingImports.isEmpty
                                  || pendingImports.contains(where: { $0.albumName.isEmpty }))
                        .accessibilityIdentifier("import.start")

                case .importing:
                    EmptyView()

                case .complete:
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("import.done")
                }
            }
            .padding()
        }
        .frame(width: 600, height: 500)
        .task {
            // Overlap the two loads — catalogAlbumCounts runs on the catalog
            // actor, the tracked-id scan on the model context.
            async let counts = syncCoordinator.catalogAlbumCounts()
            async let tracked = allTrackedAssetIds()
            catalogAlbumCounts = await counts
            globalTrackedIds = await tracked
        }
        // Library-monitor rechecks are pointless while this sheet is up: the
        // import mutates the same model context the diff reads, and iCloud
        // downloads during export make Photos post change notifications
        // continuously. The deferred recheck fires on dismiss.
        .onAppear { photosMonitor.pause() }
        .onDisappear { photosMonitor.resume() }
        .task(id: step) {
            // Watchdog: if the import has been running for 30 seconds and
            // progress is still under 40%, surface the easter-egg games offer.
            guard step == .importing else { return }
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, step == .importing else { return }
            if progress.fraction < 0.40 && !showingGames {
                withAnimation { showGamesOffer = true }
            }
        }
        .task(id: step) {
            guard step == .confirmDates else { return }
            // Recompute when the selection set has changed (e.g. user went back
            // to the album picker and picked differently); otherwise preserve
            // any edits the user already made.
            if Set(pendingImports.map(\.id)) != selectedAlbumIds {
                pendingImports = []
                await computePendingImports()
            }
        }
        .task(id: showingGames) {
            // While a game is on screen, coalesce live progress mutations into a
            // 30 Hz mirror so SwiftUI re-renders ~30×/sec instead of every mutation.
            // That gives the MainActor-paced game tick room to fire on schedule.
            guard showingGames else { return }
            while !Task.isCancelled {
                gameProgress.fraction = progress.fraction
                gameProgress.phaseLabel = progress.displayLabel
                gameProgress.currentFilename = progress.currentFilename
                gameProgress.totalFiles = progress.totalFiles
                gameProgress.currentFile = progress.currentFile
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    /// Every Photos asset id tracked by any image in the catalog. A single
    /// fetch of all records, unioning their tracked ids — no per-album
    /// relationship faulting.
    private func allTrackedAssetIds() async -> Set<String> {
        guard let records = try? modelContext.fetch(FetchDescriptor<ImageRecord>()) else { return [] }
        var ids = Set<String>()
        for record in records {
            ids.formUnion(record.allPHAssetIdentifiers)
        }
        return ids
    }

    // MARK: - Steps

    private var storageWarningView: some View {
        ContentUnavailableView {
            Label("No Archive Storage Configured", systemImage: "externaldrive.trianglebadge.exclamationmark")
        } description: {
            Text("LumiVault archives photos to external volumes and Backblaze B2, but none are set up yet. Add them in Settings first — or continue without them, and your photos will be stored in the library at ~/Pictures/LumiVault until you add archive storage.")
        } actions: {
            Button("Open Settings...") {
                dismiss()
                openSettings()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("import.openSettings")
            Button("Continue Without Archive Storage") {
                storageWarningAcknowledged = true
            }
            .accessibilityIdentifier("import.continueWithoutStorage")
        }
    }

    private var albumPickerStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select Albums")
                .font(Constants.Design.monoTitle3)
                .padding(.horizontal)
                .padding(.top, 12)

            Text("Hold \u{2318} to select multiple albums")
                .font(Constants.Design.monoCaption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal)

            PhotosAlbumPicker(
                selectedAlbumIds: $selectedAlbumIds,
                catalogAlbumCounts: catalogAlbumCounts,
                globalTrackedIds: globalTrackedIds
            )
        }
    }

    private var configureStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import Settings")
                .font(Constants.Design.monoTitle3)
                .padding(.horizontal)
                .padding(.top, 12)

            if isMultiAlbum {
                Text("Importing \(selectedAlbumIds.count) albums. You'll confirm each album's name and date in the next step.")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            ImportSettingsView(settings: $settings, showAlbumDetails: !isMultiAlbum)
        }
    }

    private var confirmDatesStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Confirm Album Dates")
                .font(Constants.Design.monoTitle3)
                .padding(.horizontal)
                .padding(.top, 12)

            Text("Dates are the median photo creation date in each album. Edit any that look wrong before continuing.")
                .font(Constants.Design.monoCaption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if isComputingDates {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Scanning \(selectedAlbumIds.count) album\(selectedAlbumIds.count == 1 ? "" : "s")…")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach($pendingImports) { $pending in
                            AlbumDateRow(pending: $pending)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var importingStep: some View {
        VStack(spacing: 16) {
            if showGamesOffer {
                gamesOfferBanner
            }

            if totalImportAlbums > 1 {
                Text("Album \(currentImportAlbumIndex) of \(totalImportAlbums): \(currentImportAlbumName)")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(progress.displayLabel)
                    .font(Constants.Design.monoHeadline)
                    .accessibilityIdentifier("import.phaseLabel")
            }

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView(value: progress.fraction)
                    Text("\(Int(progress.fraction * 100))%")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                .padding(.horizontal, 40)

                // Live status line: stage + filename + counter
                HStack(spacing: 0) {
                    if !progress.currentFilename.isEmpty {
                        if progress.phase != .importing {
                            Text(progress.currentFilename)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(progress.phase.verb)
                                .foregroundStyle(.quaternary)
                            Text(" ")
                            Text(progress.currentFilename)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 4)
                    if progress.totalFiles > 0 {
                        if progress.phase != .importing {
                            Text("\(progress.filesCataloged)/\(progress.totalFiles)")
                                .foregroundStyle(.quaternary)
                        } else {
                            Text("\(progress.currentFile)/\(progress.totalFiles)")
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
                .font(Constants.Design.monoCaption2)
                .padding(.horizontal, 40)
                .frame(height: 16)
            }

            HStack(spacing: 24) {
                if progress.filesConverted > 0 {
                    ImportStat(label: "Converted", value: progress.filesConverted)
                }
                ImportStat(label: "Hashed", value: progress.filesHashed)
                ImportStat(label: "Duplicates", value: progress.filesDeduplicated)
                if progress.nearDuplicatesFound > 0 {
                    ImportStat(label: "Near-dupes", value: progress.nearDuplicatesFound)
                }
                if progress.filesEncrypted > 0 {
                    ImportStat(label: "Encrypted", value: progress.filesEncrypted)
                }
                ImportStat(label: "PAR2", value: progress.filesProtected)
                ImportStat(label: "Copied", value: progress.filesCopied)
                ImportStat(label: "Uploaded", value: progress.filesUploaded)
            }
            .font(Constants.Design.monoCaption)

            if case .slow(let reason) = progress.health {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass")
                    Text(reason.message)
                        .lineLimit(2)
                }
                .font(Constants.Design.monoCaption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            }

            if !progress.errors.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(progress.errors.enumerated()), id: \.offset) { _, error in
                            Text(error)
                                .font(Constants.Design.monoCaption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .frame(maxHeight: 80)
                .padding(.horizontal)
            }
        }
        .padding()
    }

    private var gamesOfferBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "gamecontroller.fill")
                .foregroundStyle(Constants.Design.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("This is going to take a while.")
                    .font(Constants.Design.monoCaption)
                Text("Want to play a game while you wait?")
                    .font(Constants.Design.monoCaption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Play") { showingGames = true }
                .controlSize(.small)
                .accessibilityIdentifier("import.games.play")
            Button {
                showGamesOffer = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Constants.Design.accentColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal)
    }

    private var completeStep: some View {
        VStack(spacing: 16) {
            let hasErrors = !progress.errors.isEmpty
            let hasDropped = progress.filesDropped > 0

            Image(systemName: hasErrors || hasDropped ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(hasErrors || hasDropped ? .orange : .green)

            Text(hasErrors || hasDropped ? "Import Completed with Issues" : "Import Complete")
                .font(Constants.Design.monoTitle3)

            VStack(spacing: 4) {
                if totalImportAlbums > 1 {
                    Text("\(totalImportAlbums) albums processed")
                }
                Text("\(progress.filesCataloged) items added to album")
                if progress.filesDeduplicated > 0 {
                    Text("\(progress.filesDeduplicated) duplicates skipped")
                }
                if progress.filesDropped > 0 {
                    Text("\(progress.filesDropped) failed to import")
                        .foregroundStyle(.red)
                }
                if progress.filesCopied > 0 {
                    Text("\(progress.filesCopied) copied to storage")
                }
                if progress.filesUploaded > 0 {
                    Text("\(progress.filesUploaded) uploaded to B2")
                }
            }
            .font(Constants.Design.monoBody)
            .foregroundStyle(.secondary)

            if !progress.nearDuplicates.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(progress.nearDuplicates.count) near-duplicate\(progress.nearDuplicates.count == 1 ? "" : "s") detected")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.orange)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(progress.nearDuplicates) { match in
                            HStack(spacing: 8) {
                                NearDupeThumbnail(sha256: match.newSha256)
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                NearDupeThumbnail(sha256: match.existingSha256)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(match.newFilename)
                                        .font(Constants.Design.monoCaption)
                                        .lineLimit(1)
                                    Text("≈ \(match.existingFilename) (distance: \(match.hammingDistance))")
                                        .font(Constants.Design.monoCaption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }
                .frame(maxHeight: 120)
            }

            if !progress.skipReasons.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                Text("\(progress.filesSkipped) skipped")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(progress.skipReasons.sorted(by: { $0.key < $1.key }).enumerated()), id: \.offset) { _, entry in
                        Text("\(entry.value) × \(entry.key)")
                            .font(Constants.Design.monoCaption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }

            if !progress.errors.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                Text("\(progress.errors.count) error\(progress.errors.count == 1 ? "" : "s")")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.red)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(progress.errors.enumerated()), id: \.offset) { _, error in
                            Text(error)
                                .font(Constants.Design.monoCaption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }
                .frame(maxHeight: 120)
            }
        }
    }

    // MARK: - Actions

    private func goToSettings() {
        guard !selectedAlbumIds.isEmpty else { return }

        if selectedAlbumIds.count == 1, let albumId = selectedAlbumIds.first {
            // Single album — pre-fill settings from the selected album
            let service = PhotosImportService()
            Task {
                let albums = await service.fetchAlbums()
                if let album = albums.first(where: { $0.id == albumId }) {
                    selectedAlbumTitle = album.title
                    settings.albumName = album.title

                    let date = (await service.medianCreationDate(in: albumId, includeVideos: settings.includeVideos)) ?? .now
                    let calendar = Calendar.current
                    settings.year = String(calendar.component(.year, from: date))
                    settings.month = String(format: "%02d", calendar.component(.month, from: date))
                    settings.day = String(format: "%02d", calendar.component(.day, from: date))
                }
                step = .configure
            }
        } else {
            // Multiple albums — album details confirmed per-album in the next step
            step = .configure
        }
    }

    /// Builds the `pendingImports` list with the median creation date for each
    /// selected album. Runs once on entry to the confirmDates step.
    private func computePendingImports() async {
        isComputingDates = true
        defer { isComputingDates = false }

        let service = PhotosImportService()
        let allAlbums = await service.fetchAlbums()
        let selected = allAlbums.filter { selectedAlbumIds.contains($0.id) }

        var built: [PendingAlbumImport] = []
        built.reserveCapacity(selected.count)
        let calendar = Calendar.current
        for album in selected {
            let median = await service.medianCreationDate(in: album.id, includeVideos: settings.includeVideos)
            let date = median ?? .now
            built.append(PendingAlbumImport(
                id: album.id,
                originalTitle: album.title,
                assetCount: album.assetCount + (settings.includeVideos ? album.videoCount : 0),
                albumName: album.title,
                year: String(calendar.component(.year, from: date)),
                month: String(format: "%02d", calendar.component(.month, from: date)),
                day: String(format: "%02d", calendar.component(.day, from: date)),
                computedDate: median
            ))
        }
        pendingImports = built
    }

    private func startImport() {
        guard !selectedAlbumIds.isEmpty else { return }
        showGamesOffer = false
        showingGames = false
        step = .importing
        isImporting = true

        nonisolated(unsafe) let ctx = modelContext
        importTask = Task { @MainActor in
            // Load existing catalog so new images are appended rather than overwriting it
            try? await catalogService.load(from: Constants.Paths.resolvedCatalogURL)

            let coordinator = PipelinedImportCoordinator(catalogService: catalogService, encryptionService: encryptionService)

            if selectedAlbumIds.count > 1 {
                // Multi-album import — use the user-confirmed values from pendingImports.
                totalImportAlbums = pendingImports.count
                progress.globalTotalFiles = pendingImports.reduce(0) { $0 + $1.assetCount }
                progress.completedAlbumFiles = 0

                for (index, pending) in pendingImports.enumerated() {
                    currentImportAlbumIndex = index + 1
                    currentImportAlbumName = pending.albumName

                    var albumSettings = settings
                    albumSettings.albumName = pending.albumName
                    albumSettings.year = pending.year
                    albumSettings.month = pending.month
                    albumSettings.day = pending.day

                    // Reset per-album progress fields
                    progress.phase = .importing
                    progress.currentFile = 0
                    progress.totalFiles = 0
                    progress.currentFilename = ""
                    progress.filesCataloged = 0

                    do {
                        try await coordinator.importAlbum(
                            photosAlbumId: pending.id,
                            settings: albumSettings,
                            modelContext: ctx,
                            progress: progress
                        )
                        // Accumulate completed files for smooth global progress
                        progress.completedAlbumFiles += progress.totalFiles
                    } catch is CancellationError {
                        progress.phase = .failed
                        progress.errors.append("Import cancelled")
                        break
                    } catch {
                        progress.completedAlbumFiles += progress.totalFiles
                        progress.errors.append("Import failed for \"\(pending.albumName)\": \(error.localizedDescription)")
                    }
                }

                await syncCoordinator.pushAfterLocalChange()
            } else {
                // Single album import
                guard let albumId = selectedAlbumIds.first else { return }

                do {
                    try await coordinator.importAlbum(
                        photosAlbumId: albumId,
                        settings: settings,
                        modelContext: ctx,
                        progress: progress
                    )
                    await syncCoordinator.pushAfterLocalChange()
                } catch is CancellationError {
                    progress.phase = .failed
                    progress.errors.append("Import cancelled")
                } catch {
                    progress.errors.append("Import failed: \(error.localizedDescription)")
                    progress.phase = .failed
                }
            }

            isImporting = false
            step = .complete
        }
    }
}

// MARK: - Supporting Views

private enum ImportStep: Int, CaseIterable {
    case pickAlbum, configure, confirmDates, importing, complete

    var label: String {
        switch self {
        case .pickAlbum: "Select Albums"
        case .configure: "Settings"
        case .confirmDates: "Confirm Dates"
        case .importing: "Importing"
        case .complete: "Done"
        }
    }
}

private struct PendingAlbumImport: Identifiable, Equatable {
    let id: String
    let originalTitle: String
    let assetCount: Int
    var albumName: String
    var year: String
    var month: String
    var day: String
    /// Median creation date computed from the album's image assets, or nil if
    /// none had a creationDate. Displayed alongside the editable date so the
    /// user can tell when we couldn't infer one.
    var computedDate: Date?
}

private struct StepIndicator: View {
    let current: ImportStep
    let steps: [ImportStep]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(steps, id: \.rawValue) { step in
                HStack(spacing: 4) {
                    Circle()
                        .fill(step.rawValue <= current.rawValue ? Constants.Design.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(step.label)
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(step.rawValue <= current.rawValue ? .primary : .secondary)
                }
                if step != steps.last {
                    Rectangle()
                        .fill(step.rawValue < current.rawValue ? Constants.Design.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 1)
                        .frame(maxWidth: 40)
                }
            }
        }
    }
}

private struct AlbumDateRow: View {
    @Binding var pending: PendingAlbumImport

    private var dateBinding: Binding<Date> {
        Binding(
            get: {
                var comps = DateComponents()
                comps.year = Int(pending.year)
                comps.month = Int(pending.month)
                comps.day = Int(pending.day)
                return Calendar(identifier: .gregorian).date(from: comps) ?? .now
            },
            set: { newDate in
                let cal = Calendar(identifier: .gregorian)
                pending.year = String(cal.component(.year, from: newDate))
                pending.month = String(format: "%02d", cal.component(.month, from: newDate))
                pending.day = String(format: "%02d", cal.component(.day, from: newDate))
            }
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Album Name", text: $pending.albumName)
                    .textFieldStyle(.roundedBorder)
                    .font(Constants.Design.monoBody)
                HStack(spacing: 6) {
                    Text("\(pending.assetCount) item\(pending.assetCount == 1 ? "" : "s")")
                    if pending.computedDate == nil {
                        Text("· no creation dates found")
                            .foregroundStyle(.orange)
                    }
                }
                .font(Constants.Design.monoCaption2)
                .foregroundStyle(.tertiary)
            }
            DatePicker("", selection: dateBinding, displayedComponents: .date)
                .labelsHidden()
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct ImportStat: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .fontWeight(.medium)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NearDupeThumbnail: View {
    let sha256: String
    @Environment(\.thumbnailService) private var thumbnailService
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .task {
            thumbnail = await thumbnailService.thumbnail(for: sha256, size: .list)
        }
    }
}
