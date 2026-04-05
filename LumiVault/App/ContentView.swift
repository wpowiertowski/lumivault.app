import SwiftUI
import SwiftData

struct ContentView: View {
    @Query private var albums: [AlbumRecord]
    @State private var selectedAlbum: AlbumRecord?
    @State private var selectedImage: ImageRecord?
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var showingPhotosImport = false
    @State private var showingNearDuplicates = false

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
            ToolbarItem(placement: .navigation) {
                Button {
                    showingNearDuplicates = true
                } label: {
                    Label("Near-Duplicates", systemImage: "square.on.square.badge.person.crop")
                }
            }
        }
        .sheet(isPresented: $showingPhotosImport) {
            PhotosExportSheet()
        }
        .sheet(isPresented: $showingNearDuplicates) {
            NearDuplicatesView()
                .frame(width: 700, height: 500)
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
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @AppStorage("b2Enabled") private var b2Enabled = false
    @State private var isRestoring = false
    @State private var restoreError: String?
    @State private var restoreSuccess = false

    var body: some View {
        VStack(spacing: 0) {
            // Arrow pointing up-left toward the import button
            HStack(alignment: .bottom, spacing: 6) {
                Image(systemName: "arrow.turn.left.up")
                    .font(.system(size: 48, weight: .ultraLight))
                    .foregroundStyle(Constants.Design.accentColor.opacity(0.6))
                    .padding(.leading, 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Click to import")
                    Text("from Photos")
                }
                .font(Constants.Design.monoCaption)
                .foregroundStyle(Constants.Design.accentColor)
                .padding(.bottom, 2)

                Spacer()
            }
            .padding(.top, 8)

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

                Divider()
                    .padding(.vertical, 8)
                    .frame(width: 200)

                Text("Or restore from a backup")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("From File...") { restoreFromFile() }
                    Button("From Volume...") { restoreFromVolume() }
                    if b2Enabled {
                        Button("From B2") { restoreFromB2() }
                    }
                }
                .disabled(isRestoring)

                if isRestoring {
                    ProgressView("Restoring...")
                        .font(Constants.Design.monoCaption)
                }

                if let error = restoreError {
                    Text(error)
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.red)
                }

                if restoreSuccess {
                    Label("Catalog restored successfully", systemImage: "checkmark.circle.fill")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.green)
                }
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func restoreFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.message = "Select a catalog.json backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        performRestore(.file(url))
    }

    private func restoreFromVolume() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Select a volume containing catalog.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        performRestore(.volume(url))
    }

    private func restoreFromB2() {
        guard let data = UserDefaults.standard.data(forKey: B2Credentials.keychainKey),
              let credentials = try? JSONDecoder().decode(B2Credentials.self, from: data) else {
            restoreError = "B2 credentials not configured. Set them up in Settings > B2."
            return
        }
        performRestore(.b2(credentials))
    }

    private func performRestore(_ source: SyncCoordinator.RestoreSource) {
        isRestoring = true
        restoreError = nil
        restoreSuccess = false

        Task {
            do {
                _ = try await syncCoordinator.restoreCatalog(from: source)
                restoreSuccess = true
            } catch {
                restoreError = error.localizedDescription
            }
            isRestoring = false
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(SwiftDataContainer.create())
}
