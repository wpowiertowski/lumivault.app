import SwiftUI
import Photos

private enum AlbumSortOrder: String, CaseIterable {
    case name = "Name"
    case date = "Date"
    case count = "Count"
}

struct PhotosAlbumPicker: View {
    @Binding var selectedAlbumId: String?
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
                    AlbumPickerRow(album: album)
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
}

private struct AlbumPickerRow: View {
    let album: PhotosAlbum

    var body: some View {
        HStack {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(Constants.Design.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(Constants.Design.monoBody)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("\(album.assetCount) photos")
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
