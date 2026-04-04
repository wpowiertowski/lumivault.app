import SwiftUI
import SwiftData

struct PhotoGridView: View {
    let album: AlbumRecord
    @Binding var selectedImage: ImageRecord?

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 4)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(album.images, id: \.persistentModelID) { image in
                    PhotoGridItem(image: image, isSelected: selectedImage?.sha256 == image.sha256)
                        .onTapGesture {
                            selectedImage = image
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
