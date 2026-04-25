import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var selectedAlbum: AlbumRecord?
    @Query(sort: \AlbumRecord.year, order: .reverse) private var albums: [AlbumRecord]
    @Query private var volumes: [VolumeRecord]
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var albumToDelete: AlbumRecord?
    @State private var showingDeleteConfirmation = false
    @State private var showingDeletionProgress = false
    @State private var deletionProgress = DeletionProgress()
    @State private var albumToVerify: AlbumRecord?
    @State private var showingIntegritySheet = false
    @State private var albumToExport: AlbumRecord?
    @State private var exportDestination: URL?
    @State private var showingExportSheet = false
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @Environment(PhotosLibraryMonitor.self) private var photosMonitor
    @Environment(\.thumbnailService) private var thumbnailService
    @State private var albumToResync: AlbumRecord?
    @State private var resyncDelta: AlbumDelta?

    private var filteredAlbums: [AlbumRecord] {
        if searchText.isEmpty { return albums }
        return albums.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var albumsByYear: [String: [AlbumRecord]] {
        Dictionary(grouping: filteredAlbums, by: \.year)
    }

    private var sortedYears: [String] {
        albumsByYear.keys.sorted(by: >)
    }

    private func sortedAlbums(for year: String) -> [AlbumRecord] {
        (albumsByYear[year] ?? []).sorted {
            if $0.month != $1.month { return $0.month > $1.month }
            if $0.day != $1.day { return $0.day > $1.day }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending
        }
    }

    var body: some View {
        Group {
            if albums.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No albums yet")
                        .font(Constants.Design.monoHeadline)
                        .foregroundStyle(.secondary)
                    Text("Import albums from your\nPhotos library to get started.")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $selectedAlbum) {
                    ForEach(sortedYears, id: \.self) { year in
                        Section(year) {
                            ForEach(sortedAlbums(for: year), id: \.persistentModelID) { album in
                                NavigationLink(value: album) {
                                    AlbumRow(
                                        album: album,
                                        hasPendingSync: photosMonitor.deltas[album.persistentModelID]?.isEmpty == false,
                                        onBadgeTap: { openResync(for: album) }
                                    )
                                }
                                .accessibilityIdentifier("sidebar.album.\(album.name)")
                                .contextMenu {
                                    Button {
                                        exportAlbum(album)
                                    } label: {
                                        Label("Export Album…", systemImage: "square.and.arrow.up")
                                    }
                                    Button {
                                        albumToVerify = album
                                        showingIntegritySheet = true
                                    } label: {
                                        Label("Verify & Repair", systemImage: "checkmark.shield")
                                    }
                                    if album.photosAlbumLocalIdentifier != nil {
                                        Button {
                                            checkAndOpenResync(for: album)
                                        } label: {
                                            Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                                        }
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        albumToDelete = album
                                        showingDeleteConfirmation = true
                                    } label: {
                                        Label("Delete Album", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .searchable(text: $searchText, prompt: "Search albums")
                .accessibilityIdentifier("sidebar.albumList")
            }
        }
        .navigationTitle("Library")
        .alert("Delete Album", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) { deleteAlbum() }
            Button("Cancel", role: .cancel) { albumToDelete = nil }
        } message: {
            if let album = albumToDelete {
                Text("Delete \"\(album.name)\" and its \(album.images.count) photos? Files will be removed from all external volumes and B2.")
            }
        }
        .sheet(isPresented: $showingDeletionProgress) {
            AlbumDeletionSheet(progress: deletionProgress)
        }
        .sheet(isPresented: $showingIntegritySheet) {
            if let album = albumToVerify {
                IntegritySheet(title: album.name, images: album.images)
            }
        }
        .onChange(of: showingIntegritySheet) {
            if !showingIntegritySheet { albumToVerify = nil }
        }
        .sheet(isPresented: $showingExportSheet) {
            if let album = albumToExport, let dest = exportDestination {
                AlbumExportSheet(album: album, destinationURL: dest)
            }
        }
        .onChange(of: showingExportSheet) {
            if !showingExportSheet {
                albumToExport = nil
                exportDestination = nil
            }
        }
        .sheet(item: $albumToResync) { album in
            if let delta = resyncDelta {
                AlbumResyncSheet(album: album, delta: delta)
            }
        }
        .onChange(of: albumToResync) { _, new in
            if new == nil { resyncDelta = nil }
        }
    }

    private func openResync(for album: AlbumRecord) {
        guard let delta = photosMonitor.deltas[album.persistentModelID] else { return }
        resyncDelta = delta
        albumToResync = album
    }

    private func checkAndOpenResync(for album: AlbumRecord) {
        Task {
            let delta = await photosMonitor.recheck(album: album)
            resyncDelta = delta
            albumToResync = album
        }
    }

    private func exportAlbum(_ album: AlbumRecord) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose a destination for \"\(album.name)\""
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        albumToExport = album
        exportDestination = url
        showingExportSheet = true
    }

    private func deleteAlbum() {
        guard let album = albumToDelete else { return }
        let progress = DeletionProgress()
        self.deletionProgress = progress
        showingDeletionProgress = true

        // Snapshot image data before deletion
        let imageInputs = album.images.map { image in
            DeletionService.ImageDeletionInput(
                sha256: image.sha256,
                filename: image.filename,
                par2Filename: image.par2Filename,
                b2FileId: image.b2FileId,
                storageLocations: image.storageLocations,
                albumPath: "\(album.year)/\(album.month)/\(album.day)/\(album.name)"
            )
        }

        let albumName = album.name
        let year = album.year
        let month = album.month
        let day = album.day

        // Load B2 credentials
        var b2Credentials: B2Credentials?
        if let data = UserDefaults.standard.data(forKey: B2Credentials.defaultsKey),
           let creds = try? JSONDecoder().decode(B2Credentials.self, from: data) {
            b2Credentials = creds
        }

        // Resolve mounted volumes
        var mountedVolumes: [(volumeID: String, mountURL: URL)] = []
        for vol in volumes {
            if let url = try? BookmarkResolver.resolveAndAccess(vol.bookmarkData) {
                mountedVolumes.append((vol.volumeID, url))
            }
        }

        Task {
            let service = DeletionService()
            let result = await service.deleteImageFiles(
                images: imageInputs,
                mountedVolumes: mountedVolumes,
                b2Credentials: b2Credentials,
                progress: progress
            )

            // Stop accessing volumes
            for (_, url) in mountedVolumes {
                url.stopAccessingSecurityScopedResource()
            }

            // Update catalog
            await MainActor.run { progress.phase = .updatingCatalog }
            await syncCoordinator.removeAlbumFromCatalog(name: albumName, year: year, month: month, day: day)

            // Remove thumbnails
            let thumbSvc = thumbnailService
            for input in imageInputs {
                await thumbSvc.removeThumbnails(for: input.sha256)
            }

            // Remove from SwiftData (cascade deletes images)
            if selectedAlbum?.persistentModelID == album.persistentModelID {
                selectedAlbum = nil
            }
            modelContext.delete(album)
            try? modelContext.save()

            await MainActor.run {
                progress.phase = .complete
                progress.errors = result.errors
            }

            albumToDelete = nil

            // Distribute updated catalog in background (iCloud, volumes, B2).
            // Skip reload — in-memory catalog was already updated by removeAlbumFromCatalog.
            await syncCoordinator.pushAfterLocalChange(reloadFromDisk: false)
        }
    }
}

private struct AlbumRow: View {
    let album: AlbumRecord
    var hasPendingSync: Bool = false
    var onBadgeTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(Constants.Design.monoBody)
                    .lineLimit(1)
                Text("\(album.dateLabel) — \(album.images.count) photos")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if hasPendingSync {
                Button(action: onBadgeTap) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .yellow)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .help("Photos album has updates — click to review")
            }
        }
        .padding(.vertical, 2)
    }
}

