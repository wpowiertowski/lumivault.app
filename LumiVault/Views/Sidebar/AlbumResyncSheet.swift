import SwiftUI
import SwiftData
import Photos
import os

struct AlbumResyncSheet: View {
    let album: AlbumRecord
    let delta: AlbumDelta

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.encryptionService) private var encryptionService
    @Environment(\.thumbnailService) private var thumbnailService
    @Environment(PhotosLibraryMonitor.self) private var photosMonitor
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @Query private var volumes: [VolumeRecord]

    @State private var includeAdditions = true
    @State private var includeRemovals = true
    @State private var isResyncing = false
    @State private var resyncTask: Task<Void, Never>?
    @State private var progress = PhotosImportProgress()
    @State private var didComplete = false

    private let catalogService = CatalogService()

    private var hasAdditions: Bool { !delta.added.isEmpty }
    private var hasRemovals: Bool { !delta.removed.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sync \"\(album.name)\"")
                .font(Constants.Design.monoTitle3)
            Text("Compared with the source album in Apple Photos")
                .font(Constants.Design.monoCaption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if isResyncing || didComplete {
            progressView
        } else if delta.albumMissing {
            missingAlbumView
        } else if !hasAdditions && !hasRemovals {
            ContentUnavailableView(
                "Already in sync",
                systemImage: "checkmark.circle",
                description: Text("No additions or removals detected.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if hasAdditions {
                        additionsSection
                    }
                    if hasRemovals {
                        removalsSection
                    }
                    if !delta.untrackable.isEmpty {
                        untrackableNote
                    }
                }
                .padding()
            }
        }
    }

    private var additionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $includeAdditions) {
                Text("Add \(delta.added.count) new \(delta.added.count == 1 ? "photo" : "photos")")
                    .font(Constants.Design.monoHeadline)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(delta.added.prefix(40), id: \.localIdentifier) { asset in
                        PHAssetThumbnail(asset: asset)
                    }
                    if delta.added.count > 40 {
                        Text("+\(delta.added.count - 40) more")
                            .font(Constants.Design.monoCaption)
                            .foregroundStyle(.secondary)
                            .frame(width: 60)
                    }
                }
            }
            .frame(height: 64)
        }
    }

    private var removalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $includeRemovals) {
                Text("Remove \(delta.removed.count) \(delta.removed.count == 1 ? "photo" : "photos") no longer in Photos")
                    .font(Constants.Design.monoHeadline)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(delta.removed.prefix(40), id: \.persistentModelID) { image in
                        ImageRecordThumbnail(sha256: image.sha256)
                    }
                    if delta.removed.count > 40 {
                        Text("+\(delta.removed.count - 40) more")
                            .font(Constants.Design.monoCaption)
                            .foregroundStyle(.secondary)
                            .frame(width: 60)
                    }
                }
            }
            .frame(height: 64)
            Text("Removed photos will be deleted from all configured external volumes and Backblaze B2.")
                .font(Constants.Design.monoCaption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var untrackableNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
            Text("\(delta.untrackable.count) image\(delta.untrackable.count == 1 ? "" : "s") imported before sync was available — can't detect deletions for those.")
                .font(Constants.Design.monoCaption2)
                .foregroundStyle(.secondary)
        }
    }

    private var missingAlbumView: some View {
        ContentUnavailableView {
            Label("Album not found in Photos", systemImage: "exclamationmark.triangle")
        } description: {
            Text("The source album has been deleted or renamed. Sync cannot proceed without it.")
        }
    }

    @ViewBuilder
    private var progressView: some View {
        VStack(spacing: 16) {
            if didComplete {
                Image(systemName: progress.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(progress.errors.isEmpty ? .green : .orange)
                Text(progress.errors.isEmpty ? "Sync Complete" : "Sync Completed with Issues")
                    .font(Constants.Design.monoHeadline)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress.phase.rawValue)
                        .font(Constants.Design.monoHeadline)
                }
                ProgressView(value: progress.fraction)
                    .padding(.horizontal, 40)
            }

            if !progress.errors.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(progress.errors.enumerated()), id: \.offset) { _, err in
                            Text(err)
                                .font(Constants.Design.monoCaption)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }
                .frame(maxHeight: 140)
            }
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                resyncTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            if didComplete {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else if !isResyncing && !delta.albumMissing && (hasAdditions || hasRemovals) {
                Button("Apply") { startResync() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!includeAdditions && !includeRemovals)
            }
        }
        .padding()
    }

    private func startResync() {
        isResyncing = true

        nonisolated(unsafe) let ctx = modelContext
        let appliedDelta = AlbumDelta(
            added: includeAdditions ? delta.added : [],
            removed: includeRemovals ? delta.removed : [],
            untrackable: delta.untrackable,
            albumMissing: delta.albumMissing
        )
        nonisolated(unsafe) let resolvedAlbum = album

        // Resolve volumes and B2 credentials for removals.
        var mountedVolumes: [(volumeID: String, mountURL: URL)] = []
        if appliedDelta.removed.isEmpty == false {
            for vol in volumes {
                if let url = try? BookmarkResolver.resolveAndAccess(vol.bookmarkData) {
                    mountedVolumes.append((vol.volumeID, url))
                }
            }
        }
        var b2Credentials: B2Credentials?
        if let data = UserDefaults.standard.data(forKey: B2Credentials.defaultsKey),
           let creds = try? JSONDecoder().decode(B2Credentials.self, from: data) {
            b2Credentials = creds
        }

        // Build settings — destinations match what's in the AlbumRecord today.
        var settings = ImportSettings(
            albumName: resolvedAlbum.name,
            year: resolvedAlbum.year,
            month: resolvedAlbum.month,
            day: resolvedAlbum.day
        )
        settings.targetVolumeIDs = mountedVolumes.map(\.volumeID)
        settings.uploadToB2 = b2Credentials != nil
        settings.b2Credentials = b2Credentials
        settings.detectNearDuplicates = UserDefaults.standard.object(forKey: "importDetectNearDuplicates") as? Bool ?? true
        settings.nearDuplicateThreshold = UserDefaults.standard.object(forKey: "importNearDuplicateThreshold") as? Int ?? Constants.Dedup.nearDuplicateThreshold
        settings.generatePAR2 = UserDefaults.standard.object(forKey: "importGeneratePAR2") as? Bool ?? true

        let capturedMounted = mountedVolumes
        let capturedCreds = b2Credentials

        resyncTask = Task { @MainActor in
            try? await catalogService.load(from: Constants.Paths.resolvedCatalogURL)

            let coordinator = PipelinedImportCoordinator(
                catalogService: catalogService,
                encryptionService: encryptionService
            )

            do {
                try await coordinator.resyncAlbum(
                    albumRecord: resolvedAlbum,
                    delta: appliedDelta,
                    settings: settings,
                    modelContext: ctx,
                    progress: progress,
                    mountedVolumes: capturedMounted,
                    b2Credentials: capturedCreds
                )
            } catch is CancellationError {
                progress.errors.append("Sync cancelled")
                progress.phase = .failed
            } catch {
                progress.errors.append("Sync failed: \(error.localizedDescription)")
                progress.phase = .failed
            }

            for (_, url) in capturedMounted {
                url.stopAccessingSecurityScopedResource()
            }

            await syncCoordinator.pushAfterLocalChange(reloadFromDisk: false)
            photosMonitor.clearDelta(for: resolvedAlbum)
            await photosMonitor.recheck(album: resolvedAlbum)

            isResyncing = false
            didComplete = true
        }
    }
}

// MARK: - Thumbnails

private struct PHAssetThumbnail: View {
    let asset: PHAsset
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task {
            image = await loadThumbnail()
        }
    }

    private func loadThumbnail() async -> NSImage? {
        // PHImageManager.requestImage may invoke its handler multiple times
        // (degraded preview, iCloud progress, then final). The continuation
        // must resume exactly once — pick the first non-degraded delivery.
        await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .highQualityFormat
            opts.isNetworkAccessAllowed = true
            opts.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 112, height: 112),
                contentMode: .aspectFill,
                options: opts
            ) { img, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                let shouldResume = resumed.withLock { state -> Bool in
                    guard !state else { return false }
                    state = true
                    return true
                }
                if shouldResume {
                    continuation.resume(returning: img)
                }
            }
        }
    }
}

private struct ImageRecordThumbnail: View {
    let sha256: String
    @Environment(\.thumbnailService) private var thumbnailService
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task {
            thumbnail = await thumbnailService.thumbnail(for: sha256, size: .list)
        }
    }
}
