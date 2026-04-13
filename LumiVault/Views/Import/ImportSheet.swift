import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportSheet: View {
    let album: AlbumRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var volumes: [VolumeRecord]
    @State private var selectedURLs: [URL] = []
    @State private var isProcessing = false
    @State private var progress: ImportProgress?
    @State private var isDragTargeted = false

    private var hasB2: Bool {
        UserDefaults.standard.data(forKey: B2Credentials.defaultsKey)
            .flatMap { try? JSONDecoder().decode(B2Credentials.self, from: $0) } != nil
    }

    private var hasConnectedVolume: Bool {
        volumes.contains { volume in
            (try? BookmarkResolver.resolveAndAccess(volume.bookmarkData)).map {
                $0.stopAccessingSecurityScopedResource()
                return true
            } ?? false
        }
    }

    private var hasStorage: Bool {
        hasB2 || hasConnectedVolume
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Import Photos")
                .font(Constants.Design.monoTitle3)

            if !hasStorage {
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
            } else if let progress {
                ImportProgressView(progress: progress)
            } else {
                dropZone
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("import.cancel")

                Spacer()

                if hasStorage {
                    Button("Choose Files...") { chooseFiles() }
                        .accessibilityIdentifier("import.chooseFiles")

                    Button("Import \(selectedURLs.count) Photos") { startImport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedURLs.isEmpty || isProcessing)
                        .accessibilityIdentifier("import.importButton")
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
                    Text(selectedURLs.isEmpty ? "Drop photos here" : "\(selectedURLs.count) files selected")
                        .font(Constants.Design.monoBody)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("import.dropZone")
            .dropDestination(for: URL.self) { urls, _ in
                let imageTypes: Set<String> = ["jpg", "jpeg", "heic", "png", "tiff", "raw", "cr2", "cr3", "nef", "arw", "dng"]
                selectedURLs = urls.filter { imageTypes.contains($0.pathExtension.lowercased()) }
                return !selectedURLs.isEmpty
            } isTargeted: { targeted in
                isDragTargeted = targeted
            }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .rawImage]

        if panel.runModal() == .OK {
            selectedURLs = panel.urls
        }
    }

    private func startImport() {
        isProcessing = true
        progress = ImportProgress(total: selectedURLs.count)

        Task {
            let hasher = HasherService()
            let thumbnailer = ThumbnailService()

            for url in selectedURLs {
                do {
                    let (hash, size) = try await hasher.sha256AndSize(of: url)

                    let record = ImageRecord(
                        sha256: hash,
                        filename: url.lastPathComponent,
                        sizeBytes: size,
                        album: album
                    )
                    modelContext.insert(record)

                    try await thumbnailer.generateThumbnail(for: url, sha256: hash)
                    record.thumbnailState = .generated

                    progress?.completed += 1
                } catch {
                    progress?.failed += 1
                    progress?.completed += 1
                }
            }

            try? modelContext.save()
            isProcessing = false
        }
    }
}

@Observable
class ImportProgress {
    let total: Int
    var completed: Int = 0
    var failed: Int = 0
    var deduplicated: Int = 0

    init(total: Int) {
        self.total = total
    }

    var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }
}
