import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var selectedAlbum: AlbumRecord?
    @Query(sort: \AlbumRecord.year, order: .reverse) private var albums: [AlbumRecord]
    @State private var searchText = ""

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
