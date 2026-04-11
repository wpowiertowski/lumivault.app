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
                SyncStat(label: "Deduped", value: deduplicatedCount)
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
                SyncStat(label: "Deduped", value: deduplicatedCount)
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
        let imagesToSync = Array(images)

        Task { @MainActor in
            defer {
                volumeURL.stopAccessingSecurityScopedResource()
                for (_, url) in sourceVolumes {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            for image in imagesToSync {
                guard let album = image.album else {
                    skippedCount += 1
                    processedImages += 1
                    continue
                }

                let destBase = volumeURL
                    .appendingPathComponent(album.year, isDirectory: true)
                    .appendingPathComponent(album.month, isDirectory: true)
                    .appendingPathComponent(album.day, isDirectory: true)
                    .appendingPathComponent(album.name, isDirectory: true)

                let destFile = destBase.appendingPathComponent(image.filename)
                let relativePath = "\(album.year)/\(album.month)/\(album.day)/\(album.name)/\(image.filename)"
                let location = StorageLocation(volumeID: volumeID, relativePath: relativePath)

                // Already tracked on this volume — skip
                if image.storageLocations.contains(location) {
                    deduplicatedCount += 1
                    processedImages += 1
                    continue
                }

                // File already exists on target — verify by hash
                if FileManager.default.fileExists(atPath: destFile.path) {
                    let existingHash = try? await hasher.sha256(of: destFile)
                    if existingHash == image.sha256 {
                        image.storageLocations.append(location)
                        deduplicatedCount += 1
                    } else {
                        errors.append("Hash mismatch for \(image.filename) on \(volume.label)")
                    }
                    processedImages += 1
                    continue
                }

                // Find a source for the file on another volume
                var sourceURL: URL?
                for loc in image.storageLocations {
                    if let (_, volURL) = sourceVolumes.first(where: { $0.0.volumeID == loc.volumeID }) {
                        let candidate = volURL.appendingPathComponent(loc.relativePath)
                        if FileManager.default.fileExists(atPath: candidate.path) {
                            sourceURL = candidate
                            break
                        }
                    }
                }

                if let source = sourceURL {
                    // Copy from another volume
                    do {
                        try FileManager.default.createDirectory(at: destBase, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: source, to: destFile)
                        image.storageLocations.append(location)
                        copyPAR2(for: image, from: source.deletingLastPathComponent(), to: destBase)
                        copiedCount += 1
                    } catch {
                        errors.append("Copy failed: \(image.filename) — \(error.localizedDescription)")
                    }
                } else if let b2 = b2Service, let creds = b2Credentials, image.b2FileId != nil {
                    // Download from B2 as fallback
                    let remotePath = "\(album.year)/\(album.month)/\(album.day)/\(album.name)/\(image.filename)"
                    do {
                        let data = try await b2.downloadFile(
                            fileName: remotePath,
                            bucketId: creds.bucketId,
                            credentials: creds
                        )
                        try FileManager.default.createDirectory(at: destBase, withIntermediateDirectories: true)
                        try data.write(to: destFile, options: .atomic)
                        image.storageLocations.append(location)
                        downloadedCount += 1
                    } catch {
                        errors.append("B2 download failed: \(image.filename) — \(error.localizedDescription)")
                    }
                } else {
                    skippedCount += 1
                }

                processedImages += 1
            }

            volume.lastSyncedAt = .now
            try? modelContext.save()
            phase = .complete
        }
    }

    private func copyPAR2(for image: ImageRecord, from sourceDir: URL, to destDir: URL) {
        guard !image.par2Filename.isEmpty else { return }
        let par2Source = sourceDir.appendingPathComponent(image.par2Filename)
        let par2Dest = destDir.appendingPathComponent(image.par2Filename)
        if FileManager.default.fileExists(atPath: par2Source.path),
           !FileManager.default.fileExists(atPath: par2Dest.path) {
            try? FileManager.default.copyItem(at: par2Source, to: par2Dest)
        }
    }

    // MARK: - Types

    private enum SyncPhase {
        case ready, syncing, complete
    }
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
