import SwiftUI
import SwiftData

struct PhotosImportSheet: View {
    @Environment(\.dismiss) private var dismiss
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
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @Environment(\.encryptionService) private var encryptionService
    @Query private var volumes: [VolumeRecord]
    @State private var catalogAlbumCounts: [String: Int] = [:]

    private var isMultiAlbum: Bool { selectedAlbumIds.count > 1 }

    private let catalogService = CatalogService()

    private var hasB2: Bool {
        UserDefaults.standard.data(forKey: B2Credentials.defaultsKey)
            .flatMap { try? JSONDecoder().decode(B2Credentials.self, from: $0) } != nil
    }

    private var connectedVolumes: [VolumeRecord] {
        volumes.filter { volume in
            (try? BookmarkResolver.resolveAndAccess(volume.bookmarkData)).map {
                $0.stopAccessingSecurityScopedResource()
                return true
            } ?? false
        }
    }

    private var hasStorage: Bool {
        hasB2 || !connectedVolumes.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            StepIndicator(current: step)
                .padding()

            Divider()

            // Content
            Group {
                if !hasStorage && step == .pickAlbum {
                    storageRequiredView
                } else {
                    switch step {
                    case .pickAlbum:
                        albumPickerStep
                    case .configure:
                        configureStep
                    case .importing:
                        importingStep
                    case .complete:
                        completeStep
                    }
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
                    if hasStorage {
                        Button("Next") { goToSettings() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(selectedAlbumIds.isEmpty)
                            .accessibilityIdentifier("import.next")
                    }

                case .configure:
                    Button("Back") { step = .pickAlbum }
                        .accessibilityIdentifier("import.back")
                    Button("Start Import") { startImport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isMultiAlbum && settings.albumName.isEmpty)
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
            catalogAlbumCounts = await syncCoordinator.catalogAlbumCounts()
        }
    }

    // MARK: - Steps

    private var storageRequiredView: some View {
        ContentUnavailableView {
            Label("No Storage Configured", systemImage: "externaldrive.trianglebadge.exclamationmark")
        } description: {
            Text("Connect an external volume or configure Backblaze B2 in Settings before importing.")
        } actions: {
            Button("Open Settings...") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .buttonStyle(.borderedProminent)
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

            PhotosAlbumPicker(selectedAlbumIds: $selectedAlbumIds, catalogAlbumCounts: catalogAlbumCounts)
        }
    }

    private var configureStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import Settings")
                .font(Constants.Design.monoTitle3)
                .padding(.horizontal)
                .padding(.top, 12)

            if isMultiAlbum {
                Text("Importing \(selectedAlbumIds.count) albums. Each album will use its own name and date.")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            ImportSettingsView(settings: $settings, showAlbumDetails: !isMultiAlbum)
        }
    }

    private var importingStep: some View {
        VStack(spacing: 16) {
            if totalImportAlbums > 1 {
                Text("Album \(currentImportAlbumIndex) of \(totalImportAlbums): \(currentImportAlbumName)")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(progress.phase.rawValue)
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
                        if progress.isPipelined && progress.phase != .importing {
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
                        if progress.isPipelined && progress.phase != .importing {
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
                ImportStat(label: "Deduped", value: progress.filesDeduplicated)
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
                Text("\(progress.filesCataloged) images added to album")
                if progress.filesDeduplicated > 0 {
                    Text("\(progress.filesDeduplicated) duplicates skipped")
                }
                if progress.filesDropped > 0 {
                    Text("\(progress.filesDropped) failed to import")
                        .foregroundStyle(.red)
                }
                if progress.filesCopied > 0 {
                    Text("\(progress.filesCopied) copied to volumes")
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

                    let date = album.startDate ?? .now
                    let calendar = Calendar.current
                    settings.year = String(calendar.component(.year, from: date))
                    settings.month = String(format: "%02d", calendar.component(.month, from: date))
                    settings.day = String(format: "%02d", calendar.component(.day, from: date))
                }
                step = .configure
            }
        } else {
            // Multiple albums — album details derived per-album during import
            step = .configure
        }
    }

    private func startImport() {
        guard !selectedAlbumIds.isEmpty else { return }
        step = .importing
        isImporting = true

        nonisolated(unsafe) let ctx = modelContext
        importTask = Task { @MainActor in
            // Load existing catalog so new images are appended rather than overwriting it
            let catalogPath = NSString(string: UserDefaults.standard.string(forKey: "catalogPath") ?? Constants.Paths.defaultCatalog).expandingTildeInPath
            try? await catalogService.load(from: URL(fileURLWithPath: catalogPath))

            let coordinator = PipelinedImportCoordinator(catalogService: catalogService, encryptionService: encryptionService)

            if selectedAlbumIds.count > 1 {
                // Multi-album import
                let service = PhotosImportService()
                let allAlbums = await service.fetchAlbums()
                let selected = allAlbums.filter { selectedAlbumIds.contains($0.id) }

                totalImportAlbums = selected.count
                progress.globalTotalFiles = selected.reduce(0) { $0 + $1.assetCount }
                progress.completedAlbumFiles = 0

                for (index, album) in selected.enumerated() {
                    currentImportAlbumIndex = index + 1
                    currentImportAlbumName = album.title

                    // Build per-album settings from shared settings + album metadata
                    var albumSettings = settings
                    albumSettings.albumName = album.title
                    let date = album.startDate ?? .now
                    let calendar = Calendar.current
                    albumSettings.year = String(calendar.component(.year, from: date))
                    albumSettings.month = String(format: "%02d", calendar.component(.month, from: date))
                    albumSettings.day = String(format: "%02d", calendar.component(.day, from: date))

                    // Reset per-album progress fields
                    progress.phase = .importing
                    progress.currentFile = 0
                    progress.totalFiles = 0
                    progress.currentFilename = ""

                    do {
                        try await coordinator.importAlbum(
                            photosAlbumId: album.id,
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
                        progress.errors.append("Import failed for \"\(album.title)\": \(error.localizedDescription)")
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
    case pickAlbum, configure, importing, complete

    var label: String {
        switch self {
        case .pickAlbum: "Select Albums"
        case .configure: "Settings"
        case .importing: "Importing"
        case .complete: "Done"
        }
    }
}

private struct StepIndicator: View {
    let current: ImportStep

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ImportStep.allCases, id: \.rawValue) { step in
                HStack(spacing: 4) {
                    Circle()
                        .fill(step.rawValue <= current.rawValue ? Constants.Design.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(step.label)
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(step.rawValue <= current.rawValue ? .primary : .secondary)
                }
                if step != ImportStep.allCases.last {
                    Rectangle()
                        .fill(step.rawValue < current.rawValue ? Constants.Design.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 1)
                        .frame(maxWidth: 40)
                }
            }
        }
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
