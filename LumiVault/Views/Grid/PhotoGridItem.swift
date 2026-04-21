import SwiftUI

struct PhotoGridItem: View {
    let image: ImageRecord
    let isSelected: Bool
    let volumes: [VolumeRecord]
    @Environment(\.thumbnailService) private var thumbnailService
    @Environment(\.encryptionService) private var encryptionService
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 100, minHeight: 100)
                    .clipped()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Constants.Design.accentColor, lineWidth: 3)
            }
        }
        .accessibilityIdentifier("grid.photo.\(String(image.sha256.prefix(8)))")
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        if let cached = await thumbnailService.thumbnail(for: image.sha256, size: .grid) {
            thumbnail = cached
            return
        }
        await regenerateFromOriginal()
    }

    private func regenerateFromOriginal() async {
        let sha256 = image.sha256
        let isEncrypted = image.isEncrypted
        let nonce = image.encryptionNonce
        let locations = image.storageLocations

        for location in locations {
            guard let volume = volumes.first(where: { $0.volumeID == location.volumeID }),
                  let mountURL = try? BookmarkResolver.resolveAndAccess(volume.bookmarkData) else {
                continue
            }
            let fileURL = mountURL.appendingPathComponent(location.relativePath)

            do {
                if isEncrypted, let nonce {
                    try await thumbnailService.generateThumbnail(
                        fromEncryptedFileAt: fileURL,
                        nonce: nonce,
                        sha256: sha256,
                        encryption: encryptionService
                    )
                } else {
                    try await thumbnailService.generateThumbnail(for: fileURL, sha256: sha256)
                }
                mountURL.stopAccessingSecurityScopedResource()
                thumbnail = await thumbnailService.thumbnail(for: sha256, size: .grid)
                return
            } catch {
                mountURL.stopAccessingSecurityScopedResource()
                continue
            }
        }
    }
}
