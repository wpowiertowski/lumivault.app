import SwiftUI
import SwiftData

struct VolumeSyncSheet: View {
    let volume: VolumeRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var images: [ImageRecord]
    @Query private var allVolumes: [VolumeRecord]

    @State private var phase: SyncPhase = .ready
    @State private var totalImages = 0
    @State private var processedImages = 0
    @State private var copiedCount = 0
    @State private var downloadedCount = 0
    @State private var deduplicatedCount = 0
    @State private var skippedCount = 0
    @State private var errors: [String] = []

    private let hasher = HasherService()

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(Constants.Design.accentColor)
                Text("Sync to \(volume.label)")
                    .font(Constants.Design.monoHeadline)
            }
            .padding(.top)

            Divider()

            // Content
            switch phase {
            case .ready:
                readyView
            case .syncing:
                syncingView
            case .complete:
                completeView
            }

            Divider()

            // Actions
            HStack {
                if phase == .complete {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Start Sync") { startSync() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(phase == .syncing || images.isEmpty)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(width: 400, height: 320)
    }

    // MARK: - Views

    private var readyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("\(images.count) images in catalog")
                .font(Constants.Design.monoBody)
                .foregroundStyle(.secondary)
            Text("Existing files on the volume will be\ndetected by hash and linked without copying.")
                .font(Constants.Design.monoCaption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var syncingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView(value: fraction)
                .padding(.horizontal, 32)
            Text("Syncing \(processedImages)/\(totalImages)")
                .font(Constants.Design.monoBody)
                .foregroundStyle(.secondary)
            HStack(spacing: 20) {
                SyncStat(label: "Copied", value: copiedCount)
                if downloadedCount > 0 {
                    SyncStat(label: "From B2", value: downloadedCount)
                }
                SyncStat(label: "Duplicates", value: deduplicatedCount)
                SyncStat(label: "Skipped", value: skippedCount)
            }
            Spacer()
        }
    }

    private var completeView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            Text("Sync Complete")
                .font(Constants.Design.monoHeadline)
            HStack(spacing: 20) {
                SyncStat(label: "Copied", value: copiedCount)
                if downloadedCount > 0 {
                    SyncStat(label: "From B2", value: downloadedCount)
                }
                SyncStat(label: "Duplicates", value: deduplicatedCount)
                SyncStat(label: "Skipped", value: skippedCount)
            }
            if !errors.isEmpty {
                Text("\(errors.count) errors")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
    }

    private var fraction: Double {
        guard totalImages > 0 else { return 0 }
        return Double(processedImages) / Double(totalImages)
    }

    // MARK: - Sync Logic

    private func startSync() {
        phase = .syncing
        totalImages = images.count
        processedImages = 0
        copiedCount = 0
        downloadedCount = 0
        deduplicatedCount = 0
        skippedCount = 0
        errors = []

        guard let volumeURL = try? BookmarkResolver.resolveAndAccess(volume.bookmarkData) else {
            errors.append("Cannot access volume: \(volume.label)")
            phase = .complete
            return
        }

        // Resolve all source volumes for finding files
        var sourceVolumes: [(VolumeRecord, URL)] = []
        for v in allVolumes where v.volumeID != volume.volumeID {
            if let url = try? BookmarkResolver.resolveAndAccess(v.bookmarkData) {
                sourceVolumes.append((v, url))
            }
        }

        // Load B2 credentials for fallback downloads
        let b2Credentials: B2Credentials? = {
            guard UserDefaults.standard.bool(forKey: "b2Enabled"),
                  let data = UserDefaults.standard.data(forKey: B2Credentials.defaultsKey),
                  let creds = try? JSONDecoder().decode(B2Credentials.self, from: data) else { return nil }
            return creds
        }()
        let b2Service = b2Credentials != nil ? B2Service() : nil

        let volumeID = volume.volumeID

        // Snapshot image data for background file I/O
        // Build a lookup from sha256 -> live ImageRecord so we can update SwiftData on MainActor
        var imagesBySHA: [String: ImageRecord] = [:]
        let snapshots: [SyncImageSnapshot] = images.compactMap { image in
            guard let album = image.album else { return nil }
            imagesBySHA[image.sha256] = image
            return SyncImageSnapshot(
                sha256: image.sha256,
                filename: image.filename,
                par2Filename: image.par2Filename,
                b2FileId: image.b2FileId,
                storageLocations: image.storageLocations,
                albumYear: album.year,
                albumMonth: album.month,
                albumDay: album.day,
                albumName: album.name
            )
        }
        let skippedNoAlbum = images.count - snapshots.count
        let sourceVolumePaths: [(volumeID: String, url: URL)] = sourceVolumes.map { ($0.0.volumeID, $0.1) }

        Task { @MainActor in
            defer {
                volumeURL.stopAccessingSecurityScopedResource()
                for (_, url) in sourceVolumes {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            // Account for images without albums
            skippedCount += skippedNoAlbum
            processedImages += skippedNoAlbum

            for snap in snapshots {
                let destBase = volumeURL
                    .appendingPathComponent(snap.albumYear, isDirectory: true)
                    .appendingPathComponent(snap.albumMonth, isDirectory: true)
                    .appendingPathComponent(snap.albumDay, isDirectory: true)
                    .appendingPathComponent(snap.albumName, isDirectory: true)
                let destFile = destBase.appendingPathComponent(snap.filename)
                let relativePath = "\(snap.albumYear)/\(snap.albumMonth)/\(snap.albumDay)/\(snap.albumName)/\(snap.filename)"
                let location = StorageLocation(volumeID: volumeID, relativePath: relativePath)

                // Already tracked on this volume — skip (fast check, no I/O)
                if snap.storageLocations.contains(location) {
                    deduplicatedCount += 1
                    processedImages += 1
                    continue
                }

                // Offload file I/O to background
                let result = await Self.syncFileIO(
                    snapshot: snap,
                    destBase: destBase,
                    destFile: destFile,
                    sourceVolumePaths: sourceVolumePaths,
                    hasher: hasher,
                    b2Service: b2Service,
                    b2Credentials: b2Credentials
                )

                // Update SwiftData and progress on MainActor
                switch result {
                case .existsVerified:
                    imagesBySHA[snap.sha256]?.storageLocations.append(location)
                    deduplicatedCount += 1
                case .hashMismatch(let msg):
                    errors.append(msg)
                case .copied:
                    imagesBySHA[snap.sha256]?.storageLocations.append(location)
                    copiedCount += 1
                case .downloaded:
                    imagesBySHA[snap.sha256]?.storageLocations.append(location)
                    downloadedCount += 1
                case .skipped:
                    skippedCount += 1
                case .error(let msg):
                    errors.append(msg)
                }

                processedImages += 1
            }

            volume.lastSyncedAt = .now
            try? modelContext.save()
            phase = .complete
        }
    }

    /// Performs file I/O for a single image off the main thread.
    /// Checks existence, verifies hashes, copies files, or downloads from B2.
    nonisolated private static func syncFileIO(
        snapshot: SyncImageSnapshot,
        destBase: URL,
        destFile: URL,
        sourceVolumePaths: [(volumeID: String, url: URL)],
        hasher: HasherService,
        b2Service: B2Service?,
        b2Credentials: B2Credentials?
    ) async -> SyncFileResult {
        let fm = FileManager.default

        // File already exists on target — verify by hash
        if fm.fileExists(atPath: destFile.path) {
            let existingHash = try? await hasher.sha256(of: destFile)
            if existingHash == snapshot.sha256 {
                return .existsVerified
            } else {
                return .hashMismatch("Hash mismatch for \(snapshot.filename)")
            }
        }

        // Find a source for the file on another volume
        for loc in snapshot.storageLocations {
            if let (_, volURL) = sourceVolumePaths.first(where: { $0.volumeID == loc.volumeID }) {
                let candidate = volURL.appendingPathComponent(loc.relativePath)
                if fm.fileExists(atPath: candidate.path) {
                    do {
                        try fm.createDirectory(at: destBase, withIntermediateDirectories: true)
                        try fm.copyItem(at: candidate, to: destFile)
                        copyPAR2Files(
                            par2Filename: snapshot.par2Filename,
                            from: candidate.deletingLastPathComponent(),
                            to: destBase
                        )
                        return .copied
                    } catch {
                        return .error("Copy failed: \(snapshot.filename) — \(error.localizedDescription)")
                    }
                }
            }
        }

        // Download from B2 as fallback
        if let b2 = b2Service, let creds = b2Credentials, snapshot.b2FileId != nil {
            let remotePath = "\(snapshot.albumYear)/\(snapshot.albumMonth)/\(snapshot.albumDay)/\(snapshot.albumName)/\(snapshot.filename)"
            do {
                let data = try await b2.downloadFile(
                    fileName: remotePath,
                    bucketId: creds.bucketId,
                    credentials: creds
                )
                try fm.createDirectory(at: destBase, withIntermediateDirectories: true)
                try data.write(to: destFile, options: .atomic)
                return .downloaded
            } catch {
                return .error("B2 download failed: \(snapshot.filename) — \(error.localizedDescription)")
            }
        }

        return .skipped
    }

    nonisolated private static func copyPAR2Files(
        par2Filename: String,
        from sourceDir: URL,
        to destDir: URL
    ) {
        guard !par2Filename.isEmpty else { return }
        let par2Source = sourceDir.appendingPathComponent(par2Filename)
        let par2Dest = destDir.appendingPathComponent(par2Filename)
        if FileManager.default.fileExists(atPath: par2Source.path),
           !FileManager.default.fileExists(atPath: par2Dest.path) {
            try? FileManager.default.copyItem(at: par2Source, to: par2Dest)
        }
    }

    // MARK: - Types

    private enum SyncPhase {
        case ready, syncing, complete
    }

    private enum SyncFileResult: Sendable {
        case existsVerified
        case hashMismatch(String)
        case copied
        case downloaded
        case skipped
        case error(String)
    }
}

/// Sendable snapshot of ImageRecord data needed for background sync I/O.
private struct SyncImageSnapshot: Sendable {
    let sha256: String
    let filename: String
    let par2Filename: String
    let b2FileId: String?
    let storageLocations: [StorageLocation]
    let albumYear: String
    let albumMonth: String
    let albumDay: String
    let albumName: String
}

private struct SyncStat: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(Constants.Design.monoTitle3)
            Text(label)
                .font(Constants.Design.monoCaption)
                .foregroundStyle(.secondary)
        }
    }
}
