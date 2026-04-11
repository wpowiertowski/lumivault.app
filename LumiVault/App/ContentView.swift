import SwiftUI
import SwiftData

struct ContentView: View {
    @Query private var albums: [AlbumRecord]
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @State private var selectedAlbum: AlbumRecord?
    @State private var selectedImage: ImageRecord?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingPhotosImport = false
    @State private var showingNearDuplicates = false
    @State private var showingIntegrityAlert = false
    @State private var showingRepairNotice = false
    @State private var showingVolumes = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedAlbum: $selectedAlbum)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                .accessibilityIdentifier("nav.sidebar")
        } content: {
            if let album = selectedAlbum {
                PhotoGridView(album: album, selectedImage: $selectedImage)
            } else if albums.isEmpty {
                WelcomeView(sidebarVisible: columnVisibility == .all)
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
        .frame(minWidth: 820, minHeight: 500)
        .navigationSplitViewStyle(.prominentDetail)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showingPhotosImport = true
                } label: {
                    Label("Import from Photos", systemImage: "photo.badge.arrow.down")
                }
                .accessibilityIdentifier("toolbar.importPhotos")
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    showingNearDuplicates = true
                } label: {
                    Label("Near-Duplicates", systemImage: "square.on.square.badge.person.crop")
                }
                .accessibilityIdentifier("toolbar.nearDuplicates")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingVolumes.toggle()
                } label: {
                    Label("Volumes", systemImage: "externaldrive")
                }
                .accessibilityIdentifier("sidebar.volumeStatus")
                .popover(isPresented: $showingVolumes, arrowEdge: .bottom) {
                    VolumeListView()
                        .frame(width: 280, height: 300)
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
        .onChange(of: syncCoordinator.catalogIntegrity) {
            switch syncCoordinator.catalogIntegrity {
            case .corrupt:
                showingIntegrityAlert = true
            case .repaired:
                showingRepairNotice = true
            default:
                break
            }
        }
        .alert("Catalog Integrity Warning", isPresented: $showingIntegrityAlert) {
            Button("Restore from Backup...") {
                // Navigate to welcome/restore flow
            }
            Button("Continue Anyway", role: .cancel) { }
        } message: {
            if case .corrupt(let expected, let actual) = syncCoordinator.catalogIntegrity {
                Text("The catalog file is corrupted and PAR2 repair failed.\n\nExpected: \(String(expected.prefix(16)))...\nActual: \(String(actual.prefix(16)))...\n\nRestore from an external volume or B2 backup.")
            } else {
                Text("The catalog file may be corrupted.")
            }
        }
        .alert("Catalog Repaired", isPresented: $showingRepairNotice) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Corruption was detected in catalog.json and automatically repaired using PAR2 error correction data.")
        }
    }
}

// MARK: - Welcome View

private struct WelcomeView: View {
    var sidebarVisible: Bool
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    var body: some View {
        if hasSeenWelcome {
            ImportPromptView(sidebarVisible: sidebarVisible)
        } else {
            FirstLaunchView(hasSeenWelcome: $hasSeenWelcome)
        }
    }
}

// MARK: - First Launch View

private struct FirstLaunchView: View {
    @Binding var hasSeenWelcome: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 40)

                // Header
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundStyle(Constants.Design.accentColor)

                    Text("LUMIVAULT")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .tracking(2)
                        .foregroundStyle(Constants.Design.accentColor)

                    Text("Your photos, preserved forever.")
                        .font(Constants.Design.monoHeadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 28)

                // Overview
                VStack(alignment: .leading, spacing: 20) {
                    welcomeSection(
                        icon: "archivebox",
                        title: "What LumiVault Does",
                        body: "LumiVault archives albums from your Photos library onto external drives and Backblaze B2 cloud storage. Every file is deduplicated via SHA-256 and protected with PAR2 error correction so your photos survive bit rot and storage failures."
                    )

                    welcomeSection(
                        icon: "gearshape",
                        title: "Recommended Setup",
                        body: "Before importing, open Settings (\u{2318},) and:"
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            setupStep(
                                number: "1",
                                text: "Add at least one external volume in **Volumes** \u{2014} this is where your archived photos will be stored."
                            )
                            setupStep(
                                number: "2",
                                text: "Configure **Backblaze B2** credentials for off-site cloud backup. B2 gives you a second copy in case your drive is lost or damaged."
                            )
                        }
                    }

                    welcomeSection(
                        icon: "doc.zipper",
                        title: "Files You'll See",
                        body: "On your volumes, each photo is stored alongside PAR2 parity files:"
                    ) {
                        VStack(alignment: .leading, spacing: 6) {
                            fileRow(name: "IMG_1234.jpg", desc: "Your archived photo")
                            fileRow(name: "IMG_1234.jpg.par2", desc: "Index with verification checksums")
                            fileRow(name: "IMG_1234.jpg.vol0+N.par2", desc: "Recovery blocks for repairing corruption")
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        Text("These PAR2 files are normal \u{2014} do not delete them. They allow LumiVault (or any standard PAR2 tool) to repair your photos if bits are ever corrupted on disk.")
                            .font(Constants.Design.monoCaption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }

                    welcomeSection(
                        icon: "rectangle.3.group",
                        title: "Layout",
                        body: "The app uses a three-column layout: albums on the left, photo grid in the center, and a detail inspector on the right showing metadata, hashes, and storage locations."
                    )
                }
                .frame(maxWidth: 460)

                // Get Started button
                Button {
                    hasSeenWelcome = true
                } label: {
                    Text("Get Started")
                        .font(Constants.Design.monoHeadline)
                        .frame(maxWidth: 200)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Constants.Design.accentColor)
                .padding(.top, 32)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func welcomeSection(
        icon: String,
        title: String,
        body: String,
        @ViewBuilder extra: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(Constants.Design.monoSubheadline)
                .fontWeight(.semibold)

            Text(.init(body))
                .font(Constants.Design.monoCaption)
                .foregroundStyle(.secondary)
                .lineSpacing(3)

            extra()
        }
    }

    private func setupStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(Constants.Design.monoCaption)
                .fontWeight(.bold)
                .foregroundStyle(Constants.Design.accentColor)
                .frame(width: 16)

            Text(.init(text))
                .font(Constants.Design.monoCaption)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
        }
    }

    private func fileRow(name: String, desc: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(Constants.Design.monoCaption2)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .frame(minWidth: 200, alignment: .leading)

            Text(desc)
                .font(Constants.Design.monoCaption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Import Prompt View

private struct ImportPromptView: View {
    var sidebarVisible: Bool
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @AppStorage("b2Enabled") private var b2Enabled = false
    @State private var isRestoring = false
    @State private var restoreError: String?
    @State private var restoreSuccess = false

    var body: some View {
        VStack(spacing: 0) {
            if sidebarVisible {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .medium))
                        Text("Click to import\nfrom Photos")
                            .font(Constants.Design.monoCaption)
                    }
                    .foregroundStyle(Constants.Design.accentColor.opacity(0.6))
                    .padding(.leading, 20)
                    .padding(.top, 12)

                    Spacer()
                }
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

                Divider()
                    .padding(.vertical, 8)
                    .frame(width: 200)

                Text("Or restore from a backup")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("From File...") { restoreFromFile() }
                        .accessibilityIdentifier("welcome.restoreFile")
                    Button("From Volume...") { restoreFromVolume() }
                        .accessibilityIdentifier("welcome.restoreVolume")
                    if b2Enabled {
                        Button("From B2") { restoreFromB2() }
                            .accessibilityIdentifier("welcome.restoreB2")
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
        guard let data = UserDefaults.standard.data(forKey: B2Credentials.defaultsKey),
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
