import SwiftUI
import SwiftData
import ImageIO

struct PhotoDetailView: View {
    let image: ImageRecord
    @Query private var volumes: [VolumeRecord]
    @Environment(\.encryptionService) private var encryptionService
    @State private var fullImage: NSImage?
    @State private var exifData: EXIFData?
    @State private var failureReason: LoadFailureReason?
    @State private var isLoadingFromB2 = false
    @State private var showingInspector = true
    @State private var b2Service = B2Service()

    enum LoadFailureReason {
        case volumesDisconnected
        case fileUnreadable
    }

    var body: some View {
        HSplitView {
            // Full-resolution preview
            ZStack {
                if let fullImage {
                    Image(nsImage: fullImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoadingFromB2 {
                    ProgressView("Loading from B2...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let failureReason {
                    failureView(reason: failureReason)
                } else {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(.black.opacity(0.05))

            // Metadata inspector
            if showingInspector {
                MetadataInspector(image: image, exif: exifData)
                    .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
            }
        }
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
            failureReason = nil
            await loadFullImage()
        }
    }

    @ViewBuilder
    private func failureView(reason: LoadFailureReason) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message(for: reason))
                .font(Constants.Design.monoBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Retry") {
                    failureReason = nil
                    Task { await loadFullImage() }
                }
                if canLoadFromB2 {
                    Button("Load preview from B2 storage") {
                        Task { await loadFromB2() }
                    }
                }
            }
            .font(Constants.Design.monoCaption)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(for reason: LoadFailureReason) -> String {
        switch reason {
        case .volumesDisconnected:
            return "External volumes disconnected, please ensure the volumes are attached and mounted"
        case .fileUnreadable:
            return "Unable to load preview"
        }
    }

    private var canLoadFromB2: Bool {
        image.b2FileId != nil && Self.loadB2Credentials() != nil
    }

    private static func loadB2Credentials() -> B2Credentials? {
        guard let data = UserDefaults.standard.data(forKey: B2Credentials.defaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(B2Credentials.self, from: data)
    }

    private func loadFullImage() async {
        var accessedAnyVolume = false

        for location in image.storageLocations {
            guard let volume = volumes.first(where: { $0.volumeID == location.volumeID }),
                  let mountURL = try? BookmarkResolver.resolveAndAccess(volume.bookmarkData) else {
                continue
            }
            accessedAnyVolume = true
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
                if let loaded = NSImage(data: plaintext) {
                    fullImage = loaded
                    return
                }
            } else {
                exifData = EXIFData.extract(from: fileURL)
                if let loaded = NSImage(contentsOf: fileURL) {
                    fullImage = loaded
                    return
                }
            }
        }

        failureReason = accessedAnyVolume ? .fileUnreadable : .volumesDisconnected
    }

    private func loadFromB2() async {
        guard let fileId = image.b2FileId,
              let credentials = Self.loadB2Credentials() else {
            return
        }

        failureReason = nil
        isLoadingFromB2 = true
        defer { isLoadingFromB2 = false }

        do {
            let data = try await b2Service.downloadFile(fileId: fileId, credentials: credentials)

            let imageData: Data
            if image.isEncrypted, let nonce = image.encryptionNonce {
                imageData = try await encryptionService.decryptData(
                    data, nonce: nonce, sha256: image.sha256
                )
            } else {
                imageData = data
            }

            exifData = EXIFData.extract(from: imageData)
            if let loaded = NSImage(data: imageData) {
                fullImage = loaded
                return
            }
            failureReason = .fileUnreadable
        } catch {
            failureReason = .fileUnreadable
        }
    }
}
