import SwiftUI

struct GeneralSettingsView: View {
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @AppStorage("redundancyPercentage") private var redundancyPercentage = 10.0
    @AppStorage("thumbnailCacheLimit") private var thumbnailCacheLimit = 2.0 // GB
    @AppStorage("b2Enabled") private var b2Enabled = false
    @State private var isRestoring = false
    @State private var restoreResult: RestoreResult?

    var body: some View {
        Form {
            Section("Catalog") {
                // The catalog lives in the app's sandbox container and isn't user-relocatable
                // (a path outside the container wouldn't survive relaunch without a
                // security-scoped bookmark), so the location is shown read-only. Use the
                // Restore Catalog actions below to bring in an external catalog.
                VStack(alignment: .leading, spacing: 3) {
                    Text("Location")
                        .font(Constants.Design.monoCaption2)
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 6) {
                        Image(systemName: catalogExists ? "checkmark.circle.fill" : "questionmark.circle")
                            .foregroundStyle(catalogExists ? Color.green : Color.secondary)
                        Text(resolvedCatalogURL.path)
                            .font(Constants.Design.monoCaption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("general.resolvedPath")
                    }
                    Text(catalogExists
                        ? "Catalog file present at this location."
                        : "No catalog file here yet — it's created on first import or restore.")
                        .font(Constants.Design.monoCaption2)
                        .foregroundStyle(.tertiary)
                }

                HStack {
                    Spacer()
                    Button("Reveal in Finder") { revealInFinder() }
                        .accessibilityIdentifier("general.reveal")
                }
            }

            Section("Restore Catalog") {
                HStack(spacing: 12) {
                    Button("From File...") { restoreFromFile() }
                        .accessibilityIdentifier("general.restoreFile")
                    Button("From Volume...") { restoreFromVolume() }
                        .accessibilityIdentifier("general.restoreVolume")
                    if b2Enabled {
                        Button("From B2") { restoreFromB2() }
                            .accessibilityIdentifier("general.restoreB2")
                    }
                }
                .disabled(isRestoring)

                if isRestoring {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Restoring...")
                            .font(Constants.Design.monoCaption)
                    }
                }

                if let result = restoreResult {
                    HStack {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.success ? .green : .red)
                        Text(result.message)
                            .font(Constants.Design.monoCaption)
                            .foregroundStyle(result.success ? Color.secondary : Color.red)
                    }
                }

                Text("Restore replaces your current catalog with a backup from an external volume, B2, or a local file.")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.tertiary)
            }

            Section("Redundancy") {
                Slider(value: $redundancyPercentage, in: 5...30, step: 5) {
                    Text("Recovery data: \(Int(redundancyPercentage))%")
                }
            }

            Section("Cache") {
                Slider(value: $thumbnailCacheLimit, in: 0.5...10, step: 0.5) {
                    Text("Thumbnail cache limit: \(thumbnailCacheLimit, specifier: "%.1f") GB")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// The absolute file URL the app actually reads and writes — the single source of
    /// truth used throughout the app.
    private var resolvedCatalogURL: URL {
        Constants.Paths.resolvedCatalogURL
    }

    private var catalogExists: Bool {
        FileManager.default.fileExists(atPath: resolvedCatalogURL.path)
    }

    /// Reveal the resolved catalog file in Finder. If it doesn't exist yet, reveal the
    /// deepest ancestor directory that does, so the user still lands in the right place.
    private func revealInFinder() {
        let fm = FileManager.default
        let url = resolvedCatalogURL
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        var dir = url.deletingLastPathComponent()
        while dir.path != "/", !fm.fileExists(atPath: dir.path) {
            dir = dir.deletingLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func restoreFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.message = "Select a catalog.json backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        performRestore(.file(url))
    }

    private func restoreFromVolume() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Select a volume containing catalog.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        performRestore(.volume(url))
    }

    private func restoreFromB2() {
        guard let credentials = B2Credentials.load() else {
            restoreResult = RestoreResult(success: false, message: "B2 credentials not configured.")
            return
        }
        performRestore(.b2(credentials))
    }

    private func performRestore(_ source: SyncCoordinator.RestoreSource) {
        isRestoring = true
        restoreResult = nil

        Task {
            do {
                _ = try await syncCoordinator.restoreCatalog(from: source)
                restoreResult = RestoreResult(success: true, message: "Catalog restored successfully")
            } catch {
                restoreResult = RestoreResult(success: false, message: error.localizedDescription)
            }
            isRestoring = false
        }
    }

    private struct RestoreResult {
        let success: Bool
        let message: String
    }
}
