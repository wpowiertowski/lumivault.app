import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedAlbum: AlbumRecord?
    @State private var selectedImage: ImageRecord?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingPhotosImport = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedAlbum: $selectedAlbum)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            if let album = selectedAlbum {
                PhotoGridView(album: album, selectedImage: $selectedImage)
            } else {
                EmptyStateView(message: "Select an album")
            }
        } detail: {
            if let image = selectedImage {
                PhotoDetailView(image: image)
            } else {
                EmptyStateView(message: "Select a photo")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingPhotosImport = true
                } label: {
                    Label("Import from Photos", systemImage: "photo.badge.arrow.down")
                }
            }
        }
        .sheet(isPresented: $showingPhotosImport) {
            PhotosExportSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPhotosImport)) { _ in
            showingPhotosImport = true
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(SwiftDataContainer.create())
}
