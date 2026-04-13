import SwiftUI
import SwiftData
import ImageIO

struct PhotoDetailView: View {
    let image: ImageRecord
    @Query private var volumes: [VolumeRecord]
    @Environment(\.encryptionService) private var encryptionService
    @State private var fullImage: PlatformImage?
    @State private var exifData: EXIFData?
    @State private var loadFailed = false
    @State private var showingInspector = true

    var body: some View {
        detailContent
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        withAnimation { showingInspector.toggle() }
                    } label: {
                        Label("Inspector", systemImage: "sidebar.right")
                    }
                }
            }
            .task(id: image.sha256) {
                fullImage = nil
                exifData = nil
                loadFailed = false
                await loadFullImage()
            }
    }

    @ViewBuilder
    private var previewPane: some View {
        ZStack {
            if let fullImage {
                Image(platformImage: fullImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Unable to load preview")
                        .font(Constants.Design.monoBody)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        loadFailed = false
                        Task { await loadFullImage() }
                    }
                    .font(Constants.Design.monoCaption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.black.opacity(0.05))
    }

    @ViewBuilder
    private var detailContent: some View {
        #if os(macOS)
        HSplitView {
            previewPane

            if showingInspector {
                MetadataInspector(image: image, exif: exifData)
                    .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
            }
        }
        #else
        HStack(spacing: 0) {
            previewPane

            if showingInspector {
                MetadataInspector(image: image, exif: exifData)
                    .frame(width: 280)
            }
        }
        #endif
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
                exifData = EXIFData.extract(from: plaintext)
                if let loaded = PlatformImage(data: plaintext) {
                    fullImage = loaded
                    return
                }
            } else {
                exifData = EXIFData.extract(from: fileURL)
                if let loaded = PlatformImage(contentsOf: fileURL) {
                    fullImage = loaded
                    return
                }
            }
        }

        // All storage locations exhausted — surface the failure
        loadFailed = true
    }
}
