import SwiftUI
import SwiftData

struct VolumesSettingsView: View {
    @Query private var volumes: [VolumeRecord]
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @State private var showingSyncAlert = false
    @State private var showingSyncSheet = false
    @State private var newlyAddedVolume: VolumeRecord?
    @State private var volumeToRemove: VolumeRecord?
    @State private var showingRemoveConfirmation = false

    /// Volumes registered on the user's other Macs (via synced settings) but not here.
    private var remoteOnlyVolumes: [VolumeIdentity] {
        let localIDs = Set(volumes.map(\.volumeID))
        return SyncedSettings.knownRemoteVolumes().filter { !localIDs.contains($0.volumeID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if volumes.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "externaldrive")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No Volumes")
                        .font(Constants.Design.monoHeadline)
                        .foregroundStyle(.secondary)
                    Text("Add an external volume to start\nmirroring your photo library.")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
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
                            Button {
                                volumeToRemove = volume
                                showingRemoveConfirmation = true
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove volume")
                            .accessibilityIdentifier("volumes.remove.\(volume.volumeID)")
                        }
                    }
                    .onDelete(perform: deleteVolumes)
                }
            }

            if !remoteOnlyVolumes.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Registered on your other Macs")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                    ForEach(remoteOnlyVolumes, id: \.volumeID) { identity in
                        HStack {
                            Image(systemName: "externaldrive.badge.icloud")
                                .foregroundStyle(.secondary)
                            Text(identity.label)
                                .font(Constants.Design.monoBody)
                            Spacer()
                            Button("Locate...") { locateVolume(identity) }
                                .accessibilityIdentifier("volumes.locate.\(identity.volumeID)")
                        }
                    }
                    Text("Connect the drive and click Locate to use the same replica set on this Mac.")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            Divider()

            HStack {
                if !volumes.isEmpty {
                    Text("\(volumes.count) volume\(volumes.count == 1 ? "" : "s")")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Volume...") { addVolume() }
                    .accessibilityIdentifier("volumes.add")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .alert("Sync Catalog", isPresented: $showingSyncAlert) {
            Button("Sync Now") { showingSyncSheet = true }
            Button("Later", role: .cancel) { newlyAddedVolume = nil }
        } message: {
            Text("Sync existing catalog images to \(newlyAddedVolume?.label ?? "this volume")?")
        }
        .alert("Remove Volume", isPresented: $showingRemoveConfirmation) {
            Button("Remove", role: .destructive) { removeVolume() }
            Button("Cancel", role: .cancel) { volumeToRemove = nil }
        } message: {
            Text("Remove \"\(volumeToRemove?.label ?? "")\" from LumiVault? Files on the volume will not be deleted.")
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
            Task { await syncCoordinator.syncSettings() }
        }
    }

    /// Register a volume known from another Mac under its existing `volumeID`, so
    /// catalog `storageLocations` recorded elsewhere resolve on this Mac too.
    private func locateVolume(_ identity: VolumeIdentity) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Select the location of \"\(identity.label)\" on this Mac"

        if panel.runModal() == .OK, let url = panel.url {
            guard let bookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { return }

            let volume = VolumeRecord(
                volumeID: identity.volumeID,
                label: identity.label,
                mountPoint: url.path,
                bookmarkData: bookmark
            )
            modelContext.insert(volume)
            try? modelContext.save()
            Task { await syncCoordinator.syncSettings() }
        }
    }

    private func removeVolume() {
        guard let volume = volumeToRemove else { return }
        modelContext.delete(volume)
        try? modelContext.save()
        volumeToRemove = nil
        Task { await syncCoordinator.syncSettings() }
    }

    private func deleteVolumes(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(volumes[index])
        }
        try? modelContext.save()
        Task { await syncCoordinator.syncSettings() }
    }
}
