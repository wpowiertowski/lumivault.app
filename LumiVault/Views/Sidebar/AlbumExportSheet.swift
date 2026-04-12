import SwiftUI
import SwiftData
import CryptoKit

struct AlbumExportSheet: View {
    let album: AlbumRecord
    let destinationURL: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.encryptionService) private var encryptionService
    @Query private var volumes: [VolumeRecord]

    @State private var phase: ExportPhase = .exporting
    @State private var totalImages = 0
    @State private var processedImages = 0
    @State private var exportedCount = 0
    @State private var repairedCount = 0
    @State private var decryptedCount = 0
    @State private var b2DownloadedCount = 0
    @State private var errors: [String] = []

    private enum ExportPhase {
        case exporting
        case complete
    }

    var body: some View {
        VStack(spacing: 16) {
            if phase == .complete {
                completeView
            } else {
                exportingView
            }
        }
        .padding(24)
        .frame(width: 380)
        .interactiveDismissDisabled(phase != .complete)
        .task { await startExport() }
    }

    private var exportingView: some View {
        VStack(spacing: 12) {
            ProgressView(value: totalImages > 0 ? Double(processedImages) / Double(totalImages) : 0)
                .progressViewStyle(.linear)
                .animation(.linear(duration: 0.2), value: processedImages)

            Text("Exporting \(album.name)…")
                .font(Constants.Design.monoBody)
                .foregroundStyle(.secondary)

            if totalImages > 0 {
                Text("\(processedImages) / \(totalImages)")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.tertiary)
            }

            if b2DownloadedCount > 0 {
                Text("Downloaded \(b2DownloadedCount) from B2")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var completeView: some View {
        VStack(spacing: 12) {
            Image(systemName: errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(errors.isEmpty ? .green : .orange)

            Text("Export Complete")
                .font(Constants.Design.monoHeadline)

            VStack(alignment: .leading, spacing: 4) {
                statLine("Exported", count: exportedCount)
                if repairedCount > 0 {
                    statLine("Repaired", count: repairedCount, style: .orange)
                }
                if decryptedCount > 0 {
                    statLine("Decrypted", count: decryptedCount)
                }
                if b2DownloadedCount > 0 {
                    statLine("Downloaded from B2", count: b2DownloadedCount)
                }
            }

            if !errors.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(errors, id: \.self) { error in
                            Text(error)
                                .font(Constants.Design.monoCaption)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }

            HStack(spacing: 12) {
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: destinationURL.path)
                    dismiss()
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func statLine(_ label: String, count: Int, style: some ShapeStyle = .secondary) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .fontWeight(.medium)
            Text(label)
        }
        .font(Constants.Design.monoCaption)
        .foregroundStyle(style)
    }

    // MARK: - Export Logic

    /// Snapshot everything needed from MainActor, then run file I/O off main thread.
    private func startExport() async {
        // Snapshot image metadata on MainActor (SwiftData models aren't Sendable)
        let snapshots = album.images.map { ExportImageSnapshot(from: $0) }
        totalImages = snapshots.count

        // Resolve mounted volumes on MainActor
        let mountedVolumes: [(volumeID: String, mountURL: URL)] = volumes.compactMap { vol in
            guard let url = try? BookmarkResolver.resolveAndAccess(vol.bookmarkData) else { return nil }
            return (vol.volumeID, url)
        }

        let b2Credentials = loadB2Credentials()
        let encKey = await encryptionService.cachedKey
        let albumName = album.name
        let destURL = destinationURL

        // Move all file I/O off MainActor
        await Task.detached {
            let b2Service = B2Service()
            let redundancy = RedundancyService()
            let fm = FileManager.default
            let albumDir = destURL.appendingPathComponent(albumName, isDirectory: true)

            do {
                try fm.createDirectory(at: albumDir, withIntermediateDirectories: true)
            } catch {
                await MainActor.run {
                    errors.append("Failed to create destination folder: \(error.localizedDescription)")
                    phase = .complete
                }
                for (_, url) in mountedVolumes { url.stopAccessingSecurityScopedResource() }
                return
            }

            for snapshot in snapshots {
                let result = await Self.exportImage(
                    snapshot,
                    to: albumDir,
                    mountedVolumes: mountedVolumes,
                    b2Credentials: b2Credentials,
                    b2Service: b2Service,
                    encryptionKey: encKey,
                    redundancy: redundancy
                )

                await MainActor.run {
                    switch result {
                    case .exported:
                        exportedCount += 1
                    case .repaired:
                        exportedCount += 1
                        repairedCount += 1
                    case .decrypted:
                        exportedCount += 1
                        decryptedCount += 1
                    case .skipped:
                        break
                    case .downloadedFromB2:
                        b2DownloadedCount += 1
                    case .error(let message):
                        errors.append(message)
                    }
                    processedImages += 1
                }
            }

            for (_, url) in mountedVolumes { url.stopAccessingSecurityScopedResource() }

            await MainActor.run {
                phase = .complete
            }
        }.value
    }

    private enum ImageExportResult: Sendable {
        case exported
        case repaired
        case decrypted
        case skipped
        case downloadedFromB2
        case error(String)
    }

    /// Pure file I/O — no MainActor, no SwiftData, works entirely with Sendable snapshots.
    private static func exportImage(
        _ image: ExportImageSnapshot,
        to albumDir: URL,
        mountedVolumes: [(volumeID: String, mountURL: URL)],
        b2Credentials: B2Credentials?,
        b2Service: B2Service,
        encryptionKey: SymmetricKey?,
        redundancy: RedundancyService
    ) async -> ImageExportResult {
        let destURL = albumDir.appendingPathComponent(image.filename)
        let fm = FileManager.default

        if fm.fileExists(atPath: destURL.path) { return .skipped }

        // 1. Locate on a mounted volume
        var sourceURL: URL?
        for (volumeID, mountURL) in mountedVolumes {
            guard let loc = image.storageLocations.first(where: { $0.volumeID == volumeID }) else { continue }
            let candidateURL = mountURL.appendingPathComponent(loc.relativePath)
            if fm.fileExists(atPath: candidateURL.path) {
                sourceURL = candidateURL
                break
            }
        }

        // 2. Fallback: download from B2
        var tempB2File: URL?
        var didDownloadFromB2 = false
        if sourceURL == nil {
            guard let creds = b2Credentials,
                  let fileId = image.b2FileId, !fileId.isEmpty else {
                return .error("\(image.filename): No source available — not on any connected volume and no B2 file ID.")
            }
            do {
                let data = try await b2Service.downloadFile(fileId: fileId, credentials: creds)
                let tmpURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + image.filename)
                try data.write(to: tmpURL, options: .atomic)
                sourceURL = tmpURL
                tempB2File = tmpURL
                didDownloadFromB2 = true
            } catch {
                return .error("\(image.filename): B2 download failed — \(error.localizedDescription)")
            }
        }

        guard let fileURL = sourceURL else {
            return .error("\(image.filename): No source available.")
        }

        defer { if let tmp = tempB2File { try? fm.removeItem(at: tmp) } }

        do {
            if image.isEncrypted {
                // Decrypt — GCM tag verifies integrity
                guard let key = encryptionKey, let nonce = image.encryptionNonce else {
                    return .error("\(image.filename): Encrypted but no decryption key available. Unlock in Settings > Encryption.")
                }
                let ciphertext = try Data(contentsOf: fileURL)
                let associatedData = Data(image.sha256.utf8)
                let combined = nonce + ciphertext
                let sealedBox = try AES.GCM.SealedBox(combined: combined)
                let plaintext = try AES.GCM.open(sealedBox, using: key, authenticating: associatedData)
                try plaintext.write(to: destURL, options: .atomic)
                return .decrypted
            } else {
                // SHA-256 check
                let fileData = try Data(contentsOf: fileURL)
                let actualHash = Catalog.sha256Hex(of: fileData)

                if actualHash != image.sha256 {
                    // PAR2 repair
                    let fileDir = fileURL.deletingLastPathComponent()
                    if !image.par2Filename.isEmpty {
                        let par2URL = fileDir.appendingPathComponent(image.par2Filename)
                        if fm.fileExists(atPath: par2URL.path),
                           let repairedData = try redundancy.repair(par2URL: par2URL, corruptedFileURL: fileURL) {
                            try repairedData.write(to: destURL, options: .atomic)
                            return .repaired
                        }
                    }
                    return .error("\(image.filename): File is corrupted and PAR2 repair failed.")
                } else {
                    try fm.copyItem(at: fileURL, to: destURL)
                    if didDownloadFromB2 { return .downloadedFromB2 }
                    return .exported
                }
            }
        } catch {
            return .error("\(image.filename): \(error.localizedDescription)")
        }
    }

    private func loadB2Credentials() -> B2Credentials? {
        guard let data = UserDefaults.standard.data(forKey: B2Credentials.defaultsKey),
              let creds = try? JSONDecoder().decode(B2Credentials.self, from: data) else { return nil }
        return creds
    }
}

/// Sendable snapshot of ImageRecord fields needed for export.
private struct ExportImageSnapshot: Sendable {
    let filename: String
    let sha256: String
    let par2Filename: String
    let b2FileId: String?
    let isEncrypted: Bool
    let encryptionNonce: Data?
    let storageLocations: [StorageLocation]

    init(from record: ImageRecord) {
        self.filename = record.filename
        self.sha256 = record.sha256
        self.par2Filename = record.par2Filename
        self.b2FileId = record.b2FileId
        self.isEncrypted = record.isEncrypted
        self.encryptionNonce = record.encryptionNonce
        self.storageLocations = record.storageLocations
    }
}
