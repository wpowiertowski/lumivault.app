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

    private var albumsByYear: [String: [AlbumRecord]] {
        Dictionary(grouping: filteredAlbums, by: \.year)
    }

    private var sortedYears: [String] {
        albumsByYear.keys.sorted(by: >)
    }

    private var filteredAlbums: [AlbumRecord] {
        if searchText.isEmpty { return albums }
        return albums.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
                            ForEach(albumsByYear[year] ?? [], id: \.persistentModelID) { album in
                                NavigationLink(value: album) {
                                    AlbumRow(album: album)
                                }
                                .contextMenu {
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
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                VolumeStatusButton()
            }
        }
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
        if let data = UserDefaults.standard.data(forKey: B2Credentials.keychainKey),
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
            let catalogService = CatalogService()
            let catalogPath = NSString(string: UserDefaults.standard.string(forKey: "catalogPath") ?? Constants.Paths.defaultCatalog).expandingTildeInPath
            try? await catalogService.load(from: URL(fileURLWithPath: catalogPath))
            await catalogService.removeAlbum(name: albumName, year: year, month: month, day: day)
            try? await catalogService.save(to: URL(fileURLWithPath: catalogPath))

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
        }
    }
}

private struct AlbumRow: View {
    let album: AlbumRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(album.name)
                .font(Constants.Design.monoBody)
                .lineLimit(1)
            Text("\(album.dateLabel) — \(album.images.count) photos")
                .font(Constants.Design.monoCaption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct VolumeStatusButton: View {
    @State private var showingVolumes = false

    var body: some View {
        Button {
            showingVolumes.toggle()
        } label: {
            Label("Volumes", systemImage: "externaldrive")
        }
        .popover(isPresented: $showingVolumes) {
            VolumeListView()
                .frame(width: 280, height: 300)
        }
    }
}
