import SwiftUI
import SwiftData
import ImageIO
import AVKit

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
    @State private var player: AVPlayer?
    /// Volume kept security-scope-accessed while the player streams from it.
    @State private var scopedMountURL: URL?
    /// Decrypted/downloaded plaintext staged for playback; deleted on teardown.
    @State private var tempPlaybackURL: URL?

    enum LoadFailureReason {
        case volumesDisconnected
        case fileUnreadable
    }

    private var isVideo: Bool { image.mediaType == .video }

    var body: some View {
        HSplitView {
            // Full-resolution preview / video player
            ZStack {
                if let player {
                    VideoPlayer(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let fullImage {
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
            teardownPlayback()
            fullImage = nil
            exifData = nil
            failureReason = nil
            if isVideo {
                await loadVideo()
            } else {
                await loadFullImage()
            }
        }
        .onDisappear {
            teardownPlayback()
        }
    }

    /// Stop playback, release the volume's security scope, and remove any
    /// staged plaintext.
    private func teardownPlayback() {
        player?.pause()
        player = nil
        if let scoped = scopedMountURL {
            scoped.stopAccessingSecurityScopedResource()
            scopedMountURL = nil
        }
        if let temp = tempPlaybackURL {
            try? FileManager.default.removeItem(at: temp)
            tempPlaybackURL = nil
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
                    Task {
                        if isVideo {
                            await loadVideo()
                        } else {
                            await loadFullImage()
                        }
                    }
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
        B2Credentials.load()
    }

    /// Resolve a playable URL for a video. Unencrypted files play straight off
    /// the volume (its security scope stays open until teardown); encrypted
    /// files are decrypted to a temp file first — bounded by the encryption
    /// size cap, above which files are never stored encrypted.
    private func loadVideo() async {
        var accessedAnyVolume = false

        for location in image.storageLocations {
            guard let (mountURL, scoped) = StorageResolver.resolveMount(for: location, volumes: volumes) else {
                continue
            }
            accessedAnyVolume = true

            let fileURL = mountURL.appendingPathComponent(location.relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                if scoped { mountURL.stopAccessingSecurityScopedResource() }
                continue
            }

            if image.isEncrypted, let nonce = image.encryptionNonce {
                defer { if scoped { mountURL.stopAccessingSecurityScopedResource() } }
                guard let ciphertext = try? Data(contentsOf: fileURL),
                      let plaintext = try? await encryptionService.decryptData(
                          ciphertext, nonce: nonce, sha256: image.sha256
                      ) else {
                    continue
                }
                if startPlayback(plaintext: plaintext) { return }
            } else {
                scopedMountURL = scoped ? mountURL : nil
                player = AVPlayer(url: fileURL)
                return
            }
        }

        failureReason = accessedAnyVolume ? .fileUnreadable : .volumesDisconnected
    }

    /// Stage plaintext video bytes to a temp file and start playback.
    private func startPlayback(plaintext: Data) -> Bool {
        let ext = (image.filename as NSString).pathExtension
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-playback-\(image.sha256)")
            .appendingPathExtension(ext.isEmpty ? "mov" : ext)
        do {
            try plaintext.write(to: temp, options: .atomic)
        } catch {
            return false
        }
        tempPlaybackURL = temp
        player = AVPlayer(url: temp)
        return true
    }

    private func loadFullImage() async {
        var accessedAnyVolume = false

        for location in image.storageLocations {
            guard let (mountURL, scoped) = StorageResolver.resolveMount(for: location, volumes: volumes) else {
                continue
            }
            accessedAnyVolume = true
            defer { if scoped { mountURL.stopAccessingSecurityScopedResource() } }

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

            let mediaData: Data
            if image.isEncrypted, let nonce = image.encryptionNonce {
                mediaData = try await encryptionService.decryptData(
                    data, nonce: nonce, sha256: image.sha256
                )
            } else {
                mediaData = data
            }

            if isVideo {
                if !startPlayback(plaintext: mediaData) {
                    failureReason = .fileUnreadable
                }
                return
            }

            exifData = EXIFData.extract(from: mediaData)
            if let loaded = NSImage(data: mediaData) {
                fullImage = loaded
                return
            }
            failureReason = .fileUnreadable
        } catch {
            failureReason = .fileUnreadable
        }
    }
}
