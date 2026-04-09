import SwiftUI
import SwiftData

struct VolumeListView: View {
    @Query private var volumes: [VolumeRecord]

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
                    VolumeRow(volume: volume)
                }
            }
        }
    }
}

private struct VolumeRow: View {
    let volume: VolumeRecord

    var body: some View {
        let mounted = isMounted

        HStack(spacing: 10) {
            Image(systemName: mounted ? "externaldrive.fill" : "externaldrive")
                .font(.title3)
                .foregroundStyle(mounted ? .green : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(volume.label)
                        .font(Constants.Design.monoBody)
                    if !mounted {
                        Text("Disconnected")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.15), in: Capsule())
                    }
                }
                if mounted, let info = diskSpaceInfo {
                    HStack(spacing: 4) {
                        SpaceBar(used: info.used, total: info.total)
                            .frame(width: 60, height: 4)
                        Text("\(formatBytes(info.free)) free of \(formatBytes(info.total))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                if let synced = volume.lastSyncedAt {
                    Text("Synced \(synced, format: .relative(presentation: .named))")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never synced")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var isMounted: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: volume.mountPoint, isDirectory: &isDir)
    }

    private var diskSpaceInfo: (total: Int64, free: Int64, used: Int64)? {
        let url = URL(fileURLWithPath: volume.mountPoint)
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacity else { return nil }
        return (Int64(total), Int64(free), Int64(total - free))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct SpaceBar: View {
    let used: Int64
    let total: Int64

    var body: some View {
        GeometryReader { geo in
            let fraction = total > 0 ? CGFloat(used) / CGFloat(total) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .blue)
                    .frame(width: geo.size.width * fraction)
            }
        }
    }
}
