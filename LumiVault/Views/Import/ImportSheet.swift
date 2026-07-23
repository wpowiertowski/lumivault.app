import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportSheet: View {
    let album: AlbumRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @Environment(\.encryptionService) private var encryptionService
    @Query private var volumes: [VolumeRecord]

    @State private var selectedURLs: [URL] = []
    @State private var isProcessing = false
    @State private var didComplete = false
    @State private var progress = PhotosImportProgress()
    @State private var isDragTargeted = false
    @State private var importTask: Task<Void, Never>?

    private let catalogService = CatalogService()

    private var b2Credentials: B2Credentials? {
        B2Credentials.load()
    }

    private var connectedVolumes: [VolumeRecord] {
        volumes.filter { volume in
            (try? BookmarkResolver.resolveAndAccess(volume.bookmarkData)).map {
                $0.stopAccessingSecurityScopedResource()
                return true
            } ?? false
        }
    }

    @State private var storageWarningAcknowledged = false

    private var hasStorage: Bool {
        b2Credentials != nil || !connectedVolumes.isEmpty
    }

    private var showingStorageWarning: Bool {
        !hasStorage && !storageWarningAcknowledged
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Import Photos")
                .font(Constants.Design.monoTitle3)

            if showingStorageWarning {
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
                    Button("Continue Without Archive Storage") {
                        storageWarningAcknowledged = true
                    }
                }
            } else if didComplete {
                completeView
            } else if isProcessing {
                progressView
            } else {
                dropZone
            }

            HStack {
                Button(isProcessing ? "Cancel" : "Close") {
                    if isProcessing {
                        importTask?.cancel()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("import.cancel")

                Spacer()

                if !showingStorageWarning && !isProcessing && !didComplete {
                    Button("Choose Files...") { chooseFiles() }
                        .accessibilityIdentifier("import.chooseFiles")

                    Button("Import \(selectedURLs.count) Files") { startImport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedURLs.isEmpty)
                        .accessibilityIdentifier("import.importButton")
                }

                if didComplete {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480, height: 360)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isDragTargeted ? Constants.Design.accentColor : Color.secondary.opacity(0.3),
                style: StrokeStyle(lineWidth: 2, dash: [8])
            )
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isDragTargeted ? Constants.Design.accentColor.opacity(0.05) : .clear)
            }
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(selectedURLs.isEmpty ? "Drop photos or videos here" : "\(selectedURLs.count) files selected")
                        .font(Constants.Design.monoBody)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("import.dropZone")
            .dropDestination(for: URL.self) { urls, _ in
                selectedURLs = urls.filter { Self.isImportableFile($0) }
                return !selectedURLs.isEmpty
            } isTargeted: { targeted in
                isDragTargeted = targeted
            }
    }

    private var progressView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
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

                HStack {
                    if !progress.currentFilename.isEmpty {
                        Text(progress.currentFilename)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    if progress.totalFiles > 0 {
                        Text("\(progress.filesCataloged)/\(progress.totalFiles)")
                            .foregroundStyle(.quaternary)
                    }
                }
                .font(Constants.Design.monoCaption2)
                .frame(height: 16)
            }

            HStack(spacing: 24) {
                ImportStat(label: "Hashed", value: progress.filesHashed)
                ImportStat(label: "Duplicates", value: progress.filesDeduplicated)
                if progress.filesProtected > 0 {
                    ImportStat(label: "PAR2", value: progress.filesProtected)
                }
                if progress.filesCopied > 0 {
                    ImportStat(label: "Copied", value: progress.filesCopied)
                }
                if progress.filesUploaded > 0 {
                    ImportStat(label: "Uploaded", value: progress.filesUploaded)
                }
            }
            .font(Constants.Design.monoCaption)
        }
    }

    private var completeView: some View {
        let hasErrors = !progress.errors.isEmpty
        return VStack(spacing: 12) {
            Image(systemName: hasErrors ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(hasErrors ? .orange : .green)

            Text(hasErrors ? "Import Completed with Issues" : "Import Complete")
                .font(Constants.Design.monoHeadline)

            VStack(spacing: 2) {
                Text("\(progress.filesCataloged) items added")
                if progress.filesDeduplicated > 0 {
                    Text("\(progress.filesDeduplicated) duplicates skipped")
                }
            }
            .font(Constants.Design.monoCaption)
            .foregroundStyle(.secondary)

            if hasErrors {
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
            }
        }
    }

    /// Accepts the image extensions the pipeline has always handled, plus
    /// anything conforming to `UTType.movie` (mov, mp4, m4v, ...).
    static func isImportableFile(_ url: URL) -> Bool {
        let imageTypes: Set<String> = ["jpg", "jpeg", "heic", "png", "tiff", "raw", "cr2", "cr3", "nef", "arw", "dng"]
        let ext = url.pathExtension.lowercased()
        if imageTypes.contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .movie) ?? false
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .rawImage, .movie]

        if panel.runModal() == .OK {
            selectedURLs = panel.urls
        }
    }

    private func startImport() {
        isProcessing = true

        let creds = b2Credentials
        let volumeIDs = connectedVolumes.map { $0.volumeID }
        var importSettings = ImportSettings(
            albumName: album.name,
            year: album.year,
            month: album.month,
            day: album.day
        )
        importSettings.generatePAR2 = true
        importSettings.detectNearDuplicates = true
        importSettings.encryptFiles = false
        importSettings.uploadToB2 = creds != nil
        importSettings.targetVolumeIDs = volumeIDs
        importSettings.b2Credentials = creds
        importSettings.imageFormat = .original
        importSettings.maxDimension = .original

        nonisolated(unsafe) let ctx = modelContext
        let urls = selectedURLs
        importTask = Task { @MainActor in
            try? await catalogService.load(from: Constants.Paths.resolvedCatalogURL)
            let coordinator = PipelinedImportCoordinator(
                catalogService: catalogService,
                encryptionService: encryptionService
            )

            do {
                try await coordinator.importFiles(
                    urls: urls,
                    settings: importSettings,
                    modelContext: ctx,
                    progress: progress
                )
                await syncCoordinator.pushAfterLocalChange()
            } catch is CancellationError {
                progress.phase = .failed
                progress.errors.append("Import cancelled")
            } catch {
                progress.phase = .failed
                progress.errors.append("Import failed: \(error.localizedDescription)")
            }

            isProcessing = false
            didComplete = true
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
