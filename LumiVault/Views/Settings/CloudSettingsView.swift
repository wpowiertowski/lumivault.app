import SwiftUI

struct CloudSettingsView: View {
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @State private var syncStatus: SyncStatus = .idle

    var body: some View {
        Form {
            Section("iCloud Sync") {
                Toggle("Enable iCloud catalog sync", isOn: $iCloudSyncEnabled)

                HStack {
                    Circle()
                        .fill(syncStatusColor)
                        .frame(width: 8, height: 8)
                    Text(syncStatusLabel)
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                }

                if iCloudSyncEnabled {
                    Text("Your catalog.json will be synced to iCloud Drive, enabling access from all your Macs.")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)

                    Button("Sync Now") {
                        syncNow()
                    }
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
        switch syncStatus {
        case .idle: .secondary
        case .syncing: .orange
        case .synced: .green
        case .error: .red
        }
    }

    private var syncStatusLabel: String {
        switch syncStatus {
        case .idle: "Not syncing"
        case .syncing: "Syncing..."
        case .synced: "Up to date"
        case .error: "Sync error"
        }
    }

    private func syncNow() {
        syncStatus = .syncing
        // SyncService integration will go here
        Task {
            try? await Task.sleep(for: .seconds(1))
            syncStatus = .synced
        }
    }
}

private enum SyncStatus {
    case idle, syncing, synced, error
}
