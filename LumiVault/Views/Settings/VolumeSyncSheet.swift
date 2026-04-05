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

                // Find a source for the file
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

                guard let source = sourceURL else {
                    skippedCount += 1
                    processedImages += 1
                    continue
                }

                do {
                    try FileManager.default.createDirectory(at: destBase, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source, to: destFile)
                    image.storageLocations.append(location)

                    // Copy PAR2 if exists
                    if !image.par2Filename.isEmpty {
                        let par2Source = source.deletingLastPathComponent().appendingPathComponent(image.par2Filename)
                        let par2Dest = destBase.appendingPathComponent(image.par2Filename)
                        if FileManager.default.fileExists(atPath: par2Source.path),
                           !FileManager.default.fileExists(atPath: par2Dest.path) {
                            try FileManager.default.copyItem(at: par2Source, to: par2Dest)
                        }
                    }

                    copiedCount += 1
                } catch {
                    errors.append("Copy failed: \(image.filename) — \(error.localizedDescription)")
                }

                processedImages += 1
            }

            volume.lastSyncedAt = .now
            try? modelContext.save()
            phase = .complete
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
