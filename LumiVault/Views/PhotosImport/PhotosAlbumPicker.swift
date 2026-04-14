import SwiftUI
import Photos

private enum AlbumSortOrder: String, CaseIterable {
    case name = "Name"
    case date = "Date"
    case count = "Count"
}

enum AlbumSyncStatus {
    /// Album exists in catalog with matching image count.
    case synced
    /// Album exists in catalog but image counts differ.
    case needsUpdate(catalogCount: Int)
    /// Album not found in catalog.
    case notSynced
}

struct PhotosAlbumPicker: View {
    @Binding var selectedAlbumId: String?
    let catalogAlbumCounts: [String: Int]
    @State private var albums: [PhotosAlbum] = []
    @State private var searchText = ""
    @State private var sortOrder: AlbumSortOrder = .name
    @State private var sortAscending = true
    @State private var authStatus: PHAuthorizationStatus = .notDetermined
    @State private var isLoading = false

    private var filteredAlbums: [PhotosAlbum] {
        let filtered = searchText.isEmpty
            ? albums
            : albums.filter { $0.title.localizedCaseInsensitiveContains(searchText) }

        return filtered.sorted { a, b in
            let result: Bool
            switch sortOrder {
            case .name:
                result = a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .date:
                result = (a.startDate ?? .distantPast) < (b.startDate ?? .distantPast)
            case .count:
                result = a.assetCount < b.assetCount
            }
            return sortAscending ? result : !result
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch authStatus {
            case .authorized, .limited:
                albumList
            case .notDetermined:
                requestAccessView
            case .denied, .restricted:
                deniedView
            @unknown default:
                requestAccessView
            }
        }
        .task {
            let service = PhotosImportService()
            authStatus = service.authorizationStatus()
            if authStatus == .authorized || authStatus == .limited {
                await loadAlbums()
            }
        }
    }

    private var albumList: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Loading albums...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if albums.isEmpty {
                ContentUnavailableView {
                    Label("No Albums", systemImage: "photo.on.rectangle")
                } description: {
                    Text("No photo albums found in your Photos library.")
                }
            } else {
                HStack(spacing: 8) {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(AlbumSortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    .accessibilityIdentifier("albums.sortPicker")

                    Button {
                        sortAscending.toggle()
                    } label: {
                        Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(sortAscending ? "Ascending" : "Descending")
                    .accessibilityIdentifier("albums.sortDirection")

                    Spacer()

                    Text("\(filteredAlbums.count) albums")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                List(filteredAlbums, selection: $selectedAlbumId) { album in
                    AlbumPickerRow(album: album, syncStatus: syncStatus(for: album))
                        .tag(album.id)
                }
                .searchable(text: $searchText, prompt: "Search albums")
                .accessibilityIdentifier("albums.list")
            }
        }
    }

    private var requestAccessView: some View {
        ContentUnavailableView {
            Label("Photos Access Required", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("LumiVault needs access to your Photos library to import albums.")
        } actions: {
            Button("Grant Access") {
                Task {
                    let service = PhotosImportService()
                    authStatus = await service.requestAuthorization()
                    if authStatus == .authorized || authStatus == .limited {
                        await loadAlbums()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("albums.grantAccess")
        }
    }

    private var deniedView: some View {
        ContentUnavailableView {
            Label("Photos Access Denied", systemImage: "lock.shield")
        } description: {
            Text("Open System Settings > Privacy & Security > Photos to grant LumiVault access.")
        } actions: {
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
            }
        }
    }

    private func loadAlbums() async {
        isLoading = true
        let service = PhotosImportService()
        albums = await service.fetchAlbums()
        isLoading = false
    }

    private func syncStatus(for album: PhotosAlbum) -> AlbumSyncStatus {
        guard let catalogCount = catalogAlbumCounts[album.title] else {
            return .notSynced
        }
        if catalogCount == album.assetCount {
            return .synced
        }
        return .needsUpdate(catalogCount: catalogCount)
    }
}

private struct AlbumPickerRow: View {
    let album: PhotosAlbum
    let syncStatus: AlbumSyncStatus

    private var statusColor: Color {
        switch syncStatus {
        case .synced: .green
        case .needsUpdate: .yellow
        case .notSynced: .gray
        }
    }

    private var statusIcon: String {
        switch syncStatus {
        case .synced: "checkmark.circle.fill"
        case .needsUpdate: "arrow.triangle.2.circlepath.circle.fill"
        case .notSynced: "circle"
        }
    }

    private var statusHelp: String {
        switch syncStatus {
        case .synced:
            "Synced — \(album.assetCount) photos in album and catalog"
        case .needsUpdate(let catalogCount):
            "Needs update — album has \(album.assetCount) photos, catalog has \(catalogCount)"
        case .notSynced:
            "Not synced — album not found in catalog"
        }
    }

    var body: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 24)
                .help(statusHelp)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(Constants.Design.monoBody)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("\(album.assetCount) photos")
                    if case .needsUpdate(let catalogCount) = syncStatus {
                        Text("(\(catalogCount) in catalog)")
                            .foregroundStyle(.yellow)
                    }
                    if let start = album.startDate {
                        Text(start, format: .dateTime.year().month())
                    }
                }
                .font(Constants.Design.monoCaption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
