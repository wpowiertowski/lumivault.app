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
                        Image(systemName: image.mediaType == .video ? "video" : "photo")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .bottomLeading) {
            if image.mediaType == .video {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                    if let duration = image.durationSeconds {
                        Text(Self.durationLabel(duration))
                    }
                }
                .font(Constants.Design.monoCaption2)
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(4)
            }
        }
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

    static func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Media-type-aware regeneration from a file on a mounted volume.
    private func generate(at fileURL: URL, sha256: String, isEncrypted: Bool, nonce: Data?) async throws {
        if image.mediaType == .video {
            if isEncrypted, let nonce {
                try await thumbnailService.generateVideoThumbnail(
                    fromEncryptedFileAt: fileURL,
                    nonce: nonce,
                    sha256: sha256,
                    fileExtension: fileURL.pathExtension,
                    encryption: encryptionService
                )
            } else {
                try await thumbnailService.generateVideoThumbnail(for: fileURL, sha256: sha256)
            }
        } else if isEncrypted, let nonce {
            try await thumbnailService.generateThumbnail(
                fromEncryptedFileAt: fileURL,
                nonce: nonce,
                sha256: sha256,
                encryption: encryptionService
            )
        } else {
            try await thumbnailService.generateThumbnail(for: fileURL, sha256: sha256)
        }
    }

    private func loadThumbnail() async {
        if let cached = await thumbnailService.thumbnail(for: image.sha256, size: .grid) {
            thumbnail = cached
            if image.thumbnailState != .generated {
                image.thumbnailState = .generated
            }
            return
        }
        await regenerateFromOriginal()
    }

    private func regenerateFromOriginal() async {
        let sha256 = image.sha256
        let isEncrypted = image.isEncrypted
        let nonce = image.encryptionNonce
        let locations = image.storageLocations
        var didAttemptGeneration = false

        for location in locations {
            guard let (mountURL, scoped) = StorageResolver.resolveMount(for: location, volumes: volumes) else {
                continue
            }
            let fileURL = mountURL.appendingPathComponent(location.relativePath)
            didAttemptGeneration = true

            do {
                try await generate(at: fileURL, sha256: sha256, isEncrypted: isEncrypted, nonce: nonce)
                if scoped { mountURL.stopAccessingSecurityScopedResource() }
                thumbnail = await thumbnailService.thumbnail(for: sha256, size: .grid)
                image.thumbnailState = .generated
                return
            } catch {
                if scoped { mountURL.stopAccessingSecurityScopedResource() }
                // A locked encryption key fails every source identically — stay
                // `.pending` and retry after the user unlocks in Settings.
                if error is EncryptionService.EncryptionError { return }
                continue
            }
        }

        // Records hydrated from a synced catalog carry no storageLocations (those are
        // local-only state). All storage targets share the year/month/day/album layout,
        // so probe the library and every registered volume at the derived path and
        // re-record any location where the file actually lives.
        if await regenerateFromDerivedPath(sha256: sha256, isEncrypted: isEncrypted, nonce: nonce, known: locations) {
            return
        }

        // Last resort: pull the original from B2 and thumbnail it locally.
        if await regenerateFromB2(sha256: sha256, isEncrypted: isEncrypted, nonce: nonce) {
            return
        }

        // Only flag `.failed` if we actually reached a mounted volume and generation threw.
        // No mounted volumes → stay `.pending` so it retries when a drive is reconnected.
        if didAttemptGeneration {
            image.thumbnailState = .failed
        }
    }

    /// Probe the library and registered volumes at `year/month/day/album/filename`.
    /// Returns true when a thumbnail was generated; also records the discovered
    /// location so detail view, verify, and delete flows can use it.
    private func regenerateFromDerivedPath(
        sha256: String, isEncrypted: Bool, nonce: Data?, known: [StorageLocation]
    ) async -> Bool {
        guard let album = image.album else { return false }
        let relativePath = "\(album.year)/\(album.month)/\(album.day)/\(album.name)/\(image.filename)"

        var candidates = [StorageLocation(volumeID: Constants.Storage.libraryVolumeID, relativePath: relativePath)]
        candidates += volumes.map { StorageLocation(volumeID: $0.volumeID, relativePath: relativePath) }

        for candidate in candidates where !known.contains(candidate) {
            guard let (mountURL, scoped) = StorageResolver.resolveMount(for: candidate, volumes: volumes) else {
                continue
            }
            defer { if scoped { mountURL.stopAccessingSecurityScopedResource() } }

            let fileURL = mountURL.appendingPathComponent(candidate.relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            do {
                try await generate(at: fileURL, sha256: sha256, isEncrypted: isEncrypted, nonce: nonce)
            } catch {
                if error is EncryptionService.EncryptionError { return false }
                continue
            }

            image.storageLocations.append(candidate)
            thumbnail = await thumbnailService.thumbnail(for: sha256, size: .grid)
            image.thumbnailState = .generated
            return true
        }
        return false
    }

    /// Download the original from B2 and thumbnail it. Network failures leave the
    /// state `.pending` so the grid retries on a later appearance.
    private func regenerateFromB2(sha256: String, isEncrypted: Bool, nonce: Data?) async -> Bool {
        guard let fileId = image.b2FileId,
              let credentials = B2Credentials.load() else { return false }

        guard let raw = await B2ThumbnailFetcher.shared.fetchOriginal(fileId: fileId, credentials: credentials) else {
            return false
        }

        let plaintext: Data
        if isEncrypted, let nonce {
            guard let decrypted = try? await encryptionService.decryptData(raw, nonce: nonce, sha256: sha256) else {
                return false
            }
            plaintext = decrypted
        } else {
            plaintext = raw
        }

        if image.mediaType == .video {
            let ext = (image.filename as NSString).pathExtension
            guard (try? await thumbnailService.generateVideoThumbnail(
                fromPlaintext: plaintext, sha256: sha256, fileExtension: ext
            )) != nil else {
                return false
            }
        } else if (try? await thumbnailService.generateThumbnail(from: plaintext, sha256: sha256)) == nil {
            return false
        }
        thumbnail = await thumbnailService.thumbnail(for: sha256, size: .grid)
        image.thumbnailState = .generated
        return true
    }
}
