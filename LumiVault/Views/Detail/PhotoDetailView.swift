import SwiftUI

struct PhotoDetailView: View {
    let image: ImageRecord
    @State private var fullImage: NSImage?
    @State private var showingInspector = true

    var body: some View {
        HSplitView {
            // Full-resolution preview
            ZStack {
                if let fullImage {
                    Image(nsImage: fullImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(.black.opacity(0.05))

            // Metadata inspector
            if showingInspector {
                MetadataInspector(image: image)
                    .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    withAnimation { showingInspector.toggle() }
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
            }
        }
        .task {
            await loadFullImage()
        }
    }

    private func loadFullImage() async {
        // Resolve from first available storage location
        guard let location = image.storageLocations.first else { return }
        let url = URL(fileURLWithPath: location.relativePath)
        fullImage = NSImage(contentsOf: url)
    }
}
