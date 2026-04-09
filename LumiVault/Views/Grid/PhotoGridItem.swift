import SwiftUI

struct PhotoGridItem: View {
    let image: ImageRecord
    let isSelected: Bool
    @Environment(\.thumbnailService) private var thumbnailService
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
        thumbnail = await thumbnailService.thumbnail(for: image.sha256, size: .grid)
    }
}
