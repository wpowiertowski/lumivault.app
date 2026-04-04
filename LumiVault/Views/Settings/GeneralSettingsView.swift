import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("catalogPath") private var catalogPath = "~/.photovault/catalog.json"
    @AppStorage("redundancyPercentage") private var redundancyPercentage = 10.0
    @AppStorage("thumbnailCacheLimit") private var thumbnailCacheLimit = 2.0 // GB

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
        let defaultPath = NSString("~/.photovault/catalog.json").expandingTildeInPath
        if FileManager.default.fileExists(atPath: defaultPath) {
            catalogPath = defaultPath
        }
    }
}
