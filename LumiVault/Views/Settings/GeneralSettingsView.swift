import SwiftUI

struct GeneralSettingsView: View {
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @AppStorage("catalogPath") private var catalogPath = "~/.lumivault/catalog.json"
    @AppStorage("redundancyPercentage") private var redundancyPercentage = 10.0
    @AppStorage("thumbnailCacheLimit") private var thumbnailCacheLimit = 2.0 // GB
    @AppStorage("b2Enabled") private var b2Enabled = false
    @State private var isRestoring = false
    @State private var restoreResult: RestoreResult?

    var body: some View {
        Form {
            Section("Catalog") {
                TextField("Catalog Path", text: $catalogPath)
                    .font(Constants.Design.monoBody)

                HStack {
                    Button("Browse...") { chooseCatalogPath() }
                    Spacer()
                    Button("Detect Existing") { detectExisting() }
                }
            }

            Section("Restore Catalog") {
                HStack(spacing: 12) {
                    Button("From File...") { restoreFromFile() }
                    Button("From Volume...") { restoreFromVolume() }
                    if b2Enabled {
                        Button("From B2") { restoreFromB2() }
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

    private func chooseCatalogPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            catalogPath = url.path
        }
    }

    private func detectExisting() {
        let defaultPath = NSString("~/.lumivault/catalog.json").expandingTildeInPath
        if FileManager.default.fileExists(atPath: defaultPath) {
            catalogPath = defaultPath
        }
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
        guard let data = UserDefaults.standard.data(forKey: B2Credentials.defaultsKey),
              let credentials = try? JSONDecoder().decode(B2Credentials.self, from: data) else {
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
