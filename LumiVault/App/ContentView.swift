import SwiftUI
import SwiftData

struct ContentView: View {
    @Query private var albums: [AlbumRecord]
    @State private var selectedAlbum: AlbumRecord?
    @State private var selectedImage: ImageRecord?
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var showingPhotosImport = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedAlbum: $selectedAlbum)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            if let album = selectedAlbum {
                PhotoGridView(album: album, selectedImage: $selectedImage)
            } else if albums.isEmpty {
                WelcomeView()
            } else {
                EmptyStateView(message: "Select an album")
            }
        } detail: {
            if let image = selectedImage {
                PhotoDetailView(image: image)
            } else {
                EmptyStateView(message: "Select a photo to view details")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .navigation) {
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
        .onChange(of: selectedAlbum) {
            selectedImage = nil
        }
        .onChange(of: albums.isEmpty) {
            if !albums.isEmpty {
                columnVisibility = .all
            }
        }
    }
}

// MARK: - Welcome View

private struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 0) {
            // Arrow pointing up-left toward the import button
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Constants.Design.accentColor)
                    Text("Click to import")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(Constants.Design.accentColor)
                }
                .padding(.leading, 32)
                .padding(.top, 16)
                Spacer()
            }

            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)

                Text("LUMIVAULT")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .tracking(2)
                    .foregroundStyle(Constants.Design.accentColor)

                Text("Import an album to get started")
                    .font(Constants.Design.monoHeadline)
                    .foregroundStyle(.secondary)

                Text("Select albums from your Photos library,\narchive them with error correction,\nand back up to external drives or B2 cloud.")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
        .modelContainer(SwiftDataContainer.create())
}
