import SwiftUI
import SwiftData

struct PhotosExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var step: ExportStep = .pickAlbum
    @State private var selectedAlbumId: String?
    @State private var selectedAlbumTitle: String = ""
    @State private var settings = ExportSettings(
        albumName: "",
        year: "",
        month: "",
        day: ""
    )
    @State private var progress = ExportProgress()
    @State private var isExporting = false
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @Environment(\.encryptionService) private var encryptionService

    private let catalogService = CatalogService()

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            StepIndicator(current: step)
                .padding()

            Divider()

            // Content
            Group {
                switch step {
                case .pickAlbum:
                    albumPickerStep
                case .configure:
                    configureStep
                case .exporting:
                    exportingStep
                case .complete:
                    completeStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation buttons
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                switch step {
                case .pickAlbum:
                    Button("Next") { goToSettings() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedAlbumId == nil)

                case .configure:
                    Button("Back") { step = .pickAlbum }
                    Button("Start Export") { startExport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(settings.albumName.isEmpty)

                case .exporting:
                    EmptyView()

                case .complete:
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 600, height: 500)
    }

    // MARK: - Steps

    private var albumPickerStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select a Photos Album")
                .font(Constants.Design.monoTitle3)
                .padding(.horizontal)
                .padding(.top, 12)

            PhotosAlbumPicker(selectedAlbumId: $selectedAlbumId)
        }
    }

    private var configureStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export Settings")
                .font(Constants.Design.monoTitle3)
                .padding(.horizontal)
                .padding(.top, 12)

            ExportSettingsView(settings: $settings)
        }
    }

    private var exportingStep: some View {
        VStack(spacing: 20) {
            Text(progress.phase.rawValue)
                .font(Constants.Design.monoHeadline)

            ProgressView(value: progress.fraction) {
                if !progress.currentFilename.isEmpty {
                    Text(progress.currentFilename)
                        .font(Constants.Design.monoCaption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 40)

            HStack(spacing: 24) {
                ExportStat(label: "Hashed", value: progress.filesHashed)
                ExportStat(label: "Deduped", value: progress.filesDeduplicated)
                if progress.nearDuplicatesFound > 0 {
                    ExportStat(label: "Near-dupes", value: progress.nearDuplicatesFound)
                }
                ExportStat(label: "Copied", value: progress.filesCopied)
                ExportStat(label: "Uploaded", value: progress.filesUploaded)
            }
            .font(Constants.Design.monoCaption)

            if !progress.errors.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(progress.errors, id: \.self) { error in
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
            Image(systemName: progress.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(progress.errors.isEmpty ? .green : .orange)

            Text(progress.errors.isEmpty ? "Export Complete" : "Export Completed with Errors")
                .font(Constants.Design.monoTitle3)

            VStack(spacing: 4) {
                Text("\(progress.filesHashed) files processed")
                if progress.filesDeduplicated > 0 {
                    Text("\(progress.filesDeduplicated) duplicates skipped")
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

            if !progress.errors.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                Text("\(progress.errors.count) error\(progress.errors.count == 1 ? "" : "s")")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.red)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(progress.errors, id: \.self) { error in
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
        guard let albumId = selectedAlbumId else { return }

        // Pre-fill settings from the selected album
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
    }

    private func startExport() {
        guard let albumId = selectedAlbumId else { return }
        step = .exporting
        isExporting = true

        let ctx = modelContext
        let prog = progress
        let sett = settings
        let catSvc = catalogService
        let encSvc = encryptionService
        let sync = syncCoordinator

        Task { @MainActor in
            let coordinator = ExportCoordinator(catalogService: catSvc, encryptionService: encSvc)
            do {
                try await coordinator.export(
                    photosAlbumId: albumId,
                    settings: sett,
                    modelContext: ctx,
                    progress: prog
                )
                await sync.pushAfterLocalChange()
            } catch {
                prog.errors.append("Export failed: \(error.localizedDescription)")
                prog.phase = .failed
            }
            isExporting = false
            step = .complete
        }
    }
}

// MARK: - Supporting Views

private enum ExportStep: Int, CaseIterable {
    case pickAlbum, configure, exporting, complete

    var label: String {
        switch self {
        case .pickAlbum: "Select Album"
        case .configure: "Settings"
        case .exporting: "Exporting"
        case .complete: "Done"
        }
    }
}

private struct StepIndicator: View {
    let current: ExportStep

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ExportStep.allCases, id: \.rawValue) { step in
                HStack(spacing: 4) {
                    Circle()
                        .fill(step.rawValue <= current.rawValue ? Constants.Design.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(step.label)
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(step.rawValue <= current.rawValue ? .primary : .secondary)
                }
                if step != ExportStep.allCases.last {
                    Rectangle()
                        .fill(step.rawValue < current.rawValue ? Constants.Design.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 1)
                        .frame(maxWidth: 40)
                }
            }
        }
    }
}

private struct ExportStat: View {
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
            let service = ThumbnailService()
            thumbnail = await service.thumbnail(for: sha256, size: .list)
        }
    }
}
