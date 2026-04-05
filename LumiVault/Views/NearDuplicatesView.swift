import SwiftUI
import SwiftData

struct NearDuplicatesView: View {
    @Query private var allImages: [ImageRecord]
    @State private var groups: [NearDuplicateGroup] = []
    @State private var isScanning = false
    @State private var scanComplete = false

    private static let threshold = 5

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Near-Duplicate Detection")
                    .font(Constants.Design.monoHeadline)
                Text("Images with perceptual hash distance < \(Self.threshold)")
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
                        NearDuplicateGroupRow(group: group)
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
                if distance < Self.threshold {
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
    let members: [Member]

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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(group.members.count) similar images")
                .font(Constants.Design.monoCaption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(group.members) { member in
                    NearDuplicateMemberCard(member: member)
                }
            }

            Divider()
        }
    }
}

private struct NearDuplicateMemberCard: View {
    let member: NearDuplicateGroup.Member
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
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
        .task {
            let service = ThumbnailService()
            thumbnail = await service.thumbnail(for: member.sha256, size: .grid)
        }
    }
}
