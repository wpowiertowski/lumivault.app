import SwiftUI
import SwiftData

struct VolumesSettingsView: View {
    @Query private var volumes: [VolumeRecord]
    @Environment(\.modelContext) private var modelContext
    @State private var showingSyncAlert = false
    @State private var showingSyncSheet = false
    @State private var newlyAddedVolume: VolumeRecord?

    var body: some View {
        VStack(alignment: .leading) {
            if volumes.isEmpty {
                ContentUnavailableView {
                    Label("No Volumes", systemImage: "externaldrive")
                } description: {
                    Text("Add an external volume to start mirroring your photo library.")
                        .font(Constants.Design.monoCaption)
                }
            } else {
                List {
                    ForEach(volumes, id: \.persistentModelID) { volume in
                        HStack {
                            Image(systemName: "externaldrive.fill")
                                .foregroundStyle(Constants.Design.accentColor)
                            VStack(alignment: .leading) {
                                Text(volume.label)
                                    .font(Constants.Design.monoBody)
                                Text(volume.mountPoint)
                                    .font(Constants.Design.monoCaption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let synced = volume.lastSyncedAt {
                                Text(synced, format: .relative(presentation: .named))
                                    .font(Constants.Design.monoCaption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteVolumes)
                }
            }

            HStack {
                Button("Add Volume...") { addVolume() }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .padding(.top)
        .alert("Sync Catalog", isPresented: $showingSyncAlert) {
            Button("Sync Now") { showingSyncSheet = true }
            Button("Later", role: .cancel) { newlyAddedVolume = nil }
        } message: {
            Text("Sync existing catalog images to \(newlyAddedVolume?.label ?? "this volume")?")
        }
        .sheet(isPresented: $showingSyncSheet) {
            if let volume = newlyAddedVolume {
                VolumeSyncSheet(volume: volume)
            }
        }
    }

    private func addVolume() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Select an external volume for photo storage"

        if panel.runModal() == .OK, let url = panel.url {
            guard let bookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { return }

            let volume = VolumeRecord(
                label: url.lastPathComponent,
                mountPoint: url.path,
                bookmarkData: bookmark
            )
            modelContext.insert(volume)
            try? modelContext.save()

            newlyAddedVolume = volume
            showingSyncAlert = true
        }
    }

    private func deleteVolumes(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(volumes[index])
        }
        try? modelContext.save()
    }
}
