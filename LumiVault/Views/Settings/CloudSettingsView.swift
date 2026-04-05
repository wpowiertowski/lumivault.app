import SwiftUI

struct CloudSettingsView: View {
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @Environment(SyncCoordinator.self) private var syncCoordinator

    var body: some View {
        Form {
            Section("iCloud Sync") {
                Toggle("Enable iCloud catalog sync", isOn: $iCloudSyncEnabled)
                    .onChange(of: iCloudSyncEnabled) { _, enabled in
                        Task { await syncCoordinator.onSyncToggleChanged(enabled: enabled) }
                    }

                HStack {
                    Circle()
                        .fill(syncStatusColor)
                        .frame(width: 8, height: 8)
                    Text(syncStatusLabel)
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                }

                if iCloudSyncEnabled {
                    Text("Your catalog.json will be synced via the iCloud app container, enabling access from all your Macs.")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)

                    if let lastSynced = syncCoordinator.lastSyncedAt {
                        Text("Last synced: \(lastSynced.formatted(date: .abbreviated, time: .shortened))")
                            .font(Constants.Design.monoCaption)
                            .foregroundStyle(.secondary)
                    }

                    if let error = syncCoordinator.lastError {
                        Text(error)
                            .font(Constants.Design.monoCaption)
                            .foregroundStyle(.red)
                    }

                    Button("Sync Now") {
                        Task { await syncCoordinator.performSync() }
                    }
                    .disabled(syncCoordinator.syncStatus == .syncing)
                }

                if !syncCoordinator.isICloudAvailable && iCloudSyncEnabled {
                    Label("iCloud is not available. Sign in to iCloud in System Settings.", systemImage: "exclamationmark.triangle")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Conflict Resolution") {
                Text("When conflicts occur, albums are merged by combining images (union by SHA-256). The newest timestamp wins for shared metadata.")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var syncStatusColor: Color {
        switch syncCoordinator.syncStatus {
        case .idle: .secondary
        case .syncing: .orange
        case .synced: .green
        case .error: .red
        case .disabled: .secondary
        }
    }

    private var syncStatusLabel: String {
        switch syncCoordinator.syncStatus {
        case .idle: "Not syncing"
        case .syncing: "Syncing..."
        case .synced: "Up to date"
        case .error: "Sync error"
        case .disabled: "Disabled"
        }
    }
}
