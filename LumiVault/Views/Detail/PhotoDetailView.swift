import SwiftUI
import SwiftData

struct PhotoDetailView: View {
    let image: ImageRecord
    @Query private var volumes: [VolumeRecord]
    @Environment(\.encryptionService) private var encryptionService
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
        .task(id: image.sha256) {
            fullImage = nil
            await loadFullImage()
        }
    }

    private func loadFullImage() async {
        for location in image.storageLocations {
            guard let volume = volumes.first(where: { $0.volumeID == location.volumeID }),
                  let mountURL = try? BookmarkResolver.resolveAndAccess(volume.bookmarkData) else {
                continue
            }
            defer { mountURL.stopAccessingSecurityScopedResource() }

            let fileURL = mountURL.appendingPathComponent(location.relativePath)

            // Decrypt if encrypted
            if image.isEncrypted, let nonce = image.encryptionNonce {
                guard let ciphertext = try? Data(contentsOf: fileURL),
                      let plaintext = try? await encryptionService.decryptData(
                          ciphertext, nonce: nonce, sha256: image.sha256
                      ) else {
                    continue
                }
                if let loaded = NSImage(data: plaintext) {
                    fullImage = loaded
                    return
                }
            } else {
                if let loaded = NSImage(contentsOf: fileURL) {
                    fullImage = loaded
                    return
                }
            }
        }
    }
}
