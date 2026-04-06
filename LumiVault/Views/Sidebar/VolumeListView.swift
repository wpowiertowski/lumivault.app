import SwiftUI
import SwiftData

struct VolumeListView: View {
    @Query private var volumes: [VolumeRecord]
    @State private var mountedVolumes: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("External Volumes")
                .font(Constants.Design.monoHeadline)
                .padding(.horizontal)
                .padding(.top, 12)

            if volumes.isEmpty {
                ContentUnavailableView {
                    Label("No Volumes", systemImage: "externaldrive")
                } description: {
                    Text("Connect an external drive and add it in Settings.")
                        .font(Constants.Design.monoCaption)
                }
            } else {
                List(volumes, id: \.persistentModelID) { volume in
                    VolumeRow(volume: volume, isMounted: isMounted(volume))
                }
            }
        }
        .task {
            let service = VolumeService()
            mountedVolumes = await service.discoverMountedVolumes()
        }
    }

    private func isMounted(_ volume: VolumeRecord) -> Bool {
        mountedVolumes.contains { $0.path == volume.mountPoint }
    }
}

private struct VolumeRow: View {
    let volume: VolumeRecord
    let isMounted: Bool

    var body: some View {
        HStack {
            Image(systemName: isMounted ? "externaldrive.fill" : "externaldrive")
                .foregroundStyle(isMounted ? .green : .secondary)

            VStack(alignment: .leading) {
                Text(volume.label)
                    .font(Constants.Design.monoBody)
                if let synced = volume.lastSyncedAt {
                    Text("Synced \(synced, format: .relative(presentation: .named))")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
