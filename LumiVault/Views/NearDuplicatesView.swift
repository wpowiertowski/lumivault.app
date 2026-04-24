import SwiftUI
import SwiftData

struct NearDuplicatesView: View {
    @Query private var allImages: [ImageRecord]
    @Query private var volumes: [VolumeRecord]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @Environment(\.thumbnailService) private var thumbnailService
    @AppStorage("importNearDuplicateThreshold") private var nearDuplicateThreshold = Constants.Dedup.nearDuplicateThreshold

    @State private var groups: [NearDuplicateGroup] = []
    @State private var isScanning = false
    @State private var scanComplete = false

    @State private var pendingDelete: PendingDelete?
    @State private var showingDeleteConfirmation = false
    @State private var showingDeletionProgress = false
    @State private var deletionProgress = DeletionProgress()

    private struct PendingDelete: Equatable {
        let groupID: NearDuplicateGroup.ID
        let sha256: String
        let filename: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Delete Photo", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) { deleteImage() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let pending = pendingDelete {
                Text("Delete \"\(pending.filename)\"? The file will be removed from all external volumes and B2.")
            }
        }
        .sheet(isPresented: $showingDeletionProgress) {
            AlbumDeletionSheet(progress: deletionProgress)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Near-Duplicate Detection")
                    .font(Constants.Design.monoHeadline)
                Text("Images with perceptual hash distance < \(nearDuplicateThreshold)")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isScanning {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Scan Library") { scan() }
                .disabled(isScanning)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if !scanComplete {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("Click Scan Library to find visually similar images")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else if groups.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                Text("No near-duplicates found")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        NearDuplicateGroupRow(
                            group: group,
                            onDelete: { member in
                                pendingDelete = PendingDelete(
                                    groupID: group.id,
                                    sha256: member.sha256,
                                    filename: member.filename
                                )
                                showingDeleteConfirmation = true
                            },
                            onDismiss: {
                                groups.removeAll { $0.id == group.id }
                            }
                        )
                    }
                }
                .padding()
            }
        }
    }

    private func scan() {
        isScanning = true
        groups = []
        scanComplete = false

        Task {
            let result = findNearDuplicates(allImages)
            groups = result
            scanComplete = true
            isScanning = false
        }
    }

    private func deleteImage() {
        guard let pending = pendingDelete,
              let image = allImages.first(where: { $0.sha256 == pending.sha256 }),
              let album = image.album else {
            pendingDelete = nil
            return
        }

        let progress = DeletionProgress()
        self.deletionProgress = progress
        showingDeletionProgress = true

        let input = DeletionService.ImageDeletionInput(
            sha256: image.sha256,
            filename: image.filename,
            par2Filename: image.par2Filename,
            b2FileId: image.b2FileId,
            storageLocations: image.storageLocations,
            albumPath: "\(album.year)/\(album.month)/\(album.day)/\(album.name)"
        )

        let albumName = album.name
        let year = album.year
        let month = album.month
        let day = album.day
        let sha256 = image.sha256
        let groupID = pending.groupID

        var b2Credentials: B2Credentials?
        if let data = UserDefaults.standard.data(forKey: B2Credentials.defaultsKey),
           let creds = try? JSONDecoder().decode(B2Credentials.self, from: data) {
            b2Credentials = creds
        }

        var mountedVolumes: [(volumeID: String, mountURL: URL)] = []
        for vol in volumes {
            if let url = try? BookmarkResolver.resolveAndAccess(vol.bookmarkData) {
                mountedVolumes.append((vol.volumeID, url))
            }
        }

        Task {
            let service = DeletionService()
            let result = await service.deleteImageFiles(
                images: [input],
                mountedVolumes: mountedVolumes,
                b2Credentials: b2Credentials,
                progress: progress,
                entireAlbum: false
            )

            for (_, url) in mountedVolumes {
                url.stopAccessingSecurityScopedResource()
            }

            await MainActor.run { progress.phase = .updatingCatalog }
            await syncCoordinator.removeImageFromCatalog(sha256: sha256, albumName: albumName, year: year, month: month, day: day)

            await thumbnailService.removeThumbnails(for: sha256)

            modelContext.delete(image)
            try? modelContext.save()

            if let idx = groups.firstIndex(where: { $0.id == groupID }) {
                groups[idx].members.removeAll { $0.sha256 == sha256 }
                if groups[idx].members.count < 2 {
                    groups.remove(at: idx)
                }
            }

            await MainActor.run {
                progress.phase = .complete
                progress.errors = result.errors
            }

            pendingDelete = nil

            await syncCoordinator.pushAfterLocalChange(reloadFromDisk: false)
        }
    }

    private func findNearDuplicates(_ images: [ImageRecord]) -> [NearDuplicateGroup] {
        // Collect images that have perceptual hashes
        let hashed = images.compactMap { image -> (ImageRecord, Data)? in
            guard let hash = image.perceptualHash else { return nil }
            return (image, hash)
        }

        // Track which images are already grouped
        var grouped = Set<String>()
        var result: [NearDuplicateGroup] = []

        for i in 0..<hashed.count {
            let (imageA, hashA) = hashed[i]
            if grouped.contains(imageA.sha256) { continue }

            var members: [NearDuplicateGroup.Member] = []

            for j in (i + 1)..<hashed.count {
                let (imageB, hashB) = hashed[j]
                if grouped.contains(imageB.sha256) { continue }

                let distance = PerceptualHash.hammingDistance(hashA, hashB)
                if distance < nearDuplicateThreshold {
                    if members.isEmpty {
                        members.append(NearDuplicateGroup.Member(
                            sha256: imageA.sha256,
                            filename: imageA.filename,
                            sizeBytes: imageA.sizeBytes,
                            albumName: imageA.album?.name ?? "Unknown",
                            distanceToFirst: 0
                        ))
                        grouped.insert(imageA.sha256)
                    }
                    members.append(NearDuplicateGroup.Member(
                        sha256: imageB.sha256,
                        filename: imageB.filename,
                        sizeBytes: imageB.sizeBytes,
                        albumName: imageB.album?.name ?? "Unknown",
                        distanceToFirst: distance
                    ))
                    grouped.insert(imageB.sha256)
                }
            }

            if members.count >= 2 {
                result.append(NearDuplicateGroup(members: members))
            }
        }

        return result
    }
}

// MARK: - Models

struct NearDuplicateGroup: Identifiable {
    let id = UUID()
    var members: [Member]

    struct Member: Identifiable {
        let id = UUID()
        let sha256: String
        let filename: String
        let sizeBytes: Int64
        let albumName: String
        let distanceToFirst: Int
    }
}

// MARK: - Group Row

private struct NearDuplicateGroupRow: View {
    let group: NearDuplicateGroup
    let onDelete: (NearDuplicateGroup.Member) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(group.members.count) similar images")
                    .font(Constants.Design.monoCaption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") { onDismiss() }
                    .buttonStyle(.plain)
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(group.members) { member in
                    NearDuplicateMemberCard(
                        member: member,
                        onDelete: { onDelete(member) }
                    )
                }
            }

            Divider()
        }
    }
}

private struct NearDuplicateMemberCard: View {
    let member: NearDuplicateGroup.Member
    let onDelete: () -> Void
    @Environment(\.thumbnailService) private var thumbnailService
    @State private var thumbnail: NSImage?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(.quaternary)
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.title3)
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                if isHovered {
                    Button(action: onDelete) {
                        Image(systemName: "trash.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Delete this photo from all volumes and B2")
                }
            }
            .frame(width: 120, height: 120)

            Text(member.filename)
                .font(Constants.Design.monoCaption)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 4) {
                Text(member.albumName)
                    .foregroundStyle(.secondary)
                if member.distanceToFirst > 0 {
                    Text("d=\(member.distanceToFirst)")
                        .foregroundStyle(.orange)
                }
            }
            .font(Constants.Design.monoCaption2)

            Text(ByteCountFormatter.string(fromByteCount: member.sizeBytes, countStyle: .file))
                .font(Constants.Design.monoCaption2)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 120)
        .onHover { isHovered = $0 }
        .task {
            thumbnail = await thumbnailService.thumbnail(for: member.sha256, size: .grid)
        }
    }
}
