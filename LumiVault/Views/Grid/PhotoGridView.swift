import SwiftUI
import SwiftData

struct PhotoGridView: View {
    let album: AlbumRecord
    @Binding var selectedImage: ImageRecord?
    @Query private var volumes: [VolumeRecord]
    @Environment(\.modelContext) private var modelContext
    @State private var imageToDelete: ImageRecord?
    @State private var showingDeleteConfirmation = false
    @State private var showingDeletionProgress = false
    @State private var deletionProgress = DeletionProgress()
    @Environment(SyncCoordinator.self) private var syncCoordinator

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 4)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(album.images.sorted(by: { $0.addedAt < $1.addedAt }), id: \.persistentModelID) { image in
                    PhotoGridItem(image: image, isSelected: selectedImage?.sha256 == image.sha256)
                        .onTapGesture {
                            selectedImage = image
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                imageToDelete = image
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete Photo", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(8)
        }
        .navigationTitle(album.name)
        .navigationSubtitle("\(album.images.count) photos")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ImportButton(album: album)
            }
        }
        .alert("Delete Photo", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) { deleteImage() }
            Button("Cancel", role: .cancel) { imageToDelete = nil }
        } message: {
            if let image = imageToDelete {
                Text("Delete \"\(image.filename)\"? The file will be removed from all external volumes and B2.")
            }
        }
        .sheet(isPresented: $showingDeletionProgress) {
            AlbumDeletionSheet(progress: deletionProgress)
        }
    }

    private func deleteImage() {
        guard let image = imageToDelete else { return }
        let progress = DeletionProgress()
        self.deletionProgress = progress
        showingDeletionProgress = true

        let input = DeletionService.ImageDeletionInput(
            sha256: image.sha256,
            filename: image.filename,
            par2Filename: image.par2Filename,
            b2FileId: image.b2FileId,
            storageLocations: image.storageLocations,
            albumPath: "\(album.year)/\(album.month)/\(album.day)/\(album.name)"
        )

        let albumName = album.name
        let year = album.year
        let month = album.month
        let day = album.day
        let sha256 = image.sha256

        var b2Credentials: B2Credentials?
        if let data = UserDefaults.standard.data(forKey: B2Credentials.keychainKey),
           let creds = try? JSONDecoder().decode(B2Credentials.self, from: data) {
            b2Credentials = creds
        }

        var mountedVolumes: [(volumeID: String, mountURL: URL)] = []
        for vol in volumes {
            if let url = try? BookmarkResolver.resolveAndAccess(vol.bookmarkData) {
                mountedVolumes.append((vol.volumeID, url))
            }
        }

        Task {
            let service = DeletionService()
            let result = await service.deleteImageFiles(
                images: [input],
                mountedVolumes: mountedVolumes,
                b2Credentials: b2Credentials,
                progress: progress
            )

            for (_, url) in mountedVolumes {
                url.stopAccessingSecurityScopedResource()
            }

            // Update catalog
            await MainActor.run { progress.phase = .updatingCatalog }
            let catalogService = CatalogService()
            let catalogPath = NSString(string: UserDefaults.standard.string(forKey: "catalogPath") ?? Constants.Paths.defaultCatalog).expandingTildeInPath
            try? await catalogService.load(from: URL(fileURLWithPath: catalogPath))
            await catalogService.removeImage(sha256: sha256, fromAlbum: albumName, year: year, month: month, day: day)
            try? await catalogService.save(to: URL(fileURLWithPath: catalogPath))
            await syncCoordinator.pushAfterLocalChange()

            // Remove from SwiftData
            if selectedImage?.sha256 == sha256 {
                selectedImage = nil
            }
            modelContext.delete(image)
            try? modelContext.save()

            await MainActor.run {
                progress.phase = .complete
                progress.errors = result.errors
            }

            imageToDelete = nil
        }
    }
}

private struct ImportButton: View {
    let album: AlbumRecord
    @State private var showingImport = false

    var body: some View {
        Button {
            showingImport.toggle()
        } label: {
            Label("Import", systemImage: "plus")
        }
        .sheet(isPresented: $showingImport) {
            ImportSheet(album: album)
        }
    }
}
