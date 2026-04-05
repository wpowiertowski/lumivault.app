import SwiftUI
import SwiftData

struct ExportSettingsView: View {
    @Binding var settings: ExportSettings
    @Query private var volumes: [VolumeRecord]
    @AppStorage("b2Enabled") private var b2Enabled = false
    @AppStorage("encryptionEnabled") private var encryptionEnabled = false

    private var encryptionKeyAvailable: Bool {
        encryptionEnabled && EncryptionService.storedKeyId() != nil
    }

    var body: some View {
        Form {
            Section("Album Details") {
                TextField("Album Name", text: $settings.albumName)
                    .font(Constants.Design.monoBody)

                HStack(spacing: 12) {
                    TextField("Year", text: $settings.year)
                        .frame(minWidth: 70)
                    TextField("Month", text: $settings.month)
                        .frame(minWidth: 55)
                    TextField("Day", text: $settings.day)
                        .frame(minWidth: 55)
                }
                .font(Constants.Design.monoBody)
            }

            Section("Recovery") {
                Toggle("Generate PAR2 error correction", isOn: $settings.generatePAR2)
            }

            Section("Deduplication") {
                Toggle("Detect near-duplicate images", isOn: $settings.detectNearDuplicates)
                Text("Uses perceptual hashing to flag visually similar images during import.")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.tertiary)
            }

            Section("Encryption") {
                Toggle("Encrypt files at rest", isOn: $settings.encryptFiles)
                    .disabled(!encryptionKeyAvailable)
                if settings.encryptFiles {
                    Text("Files will be encrypted with AES-256-GCM before storage. PAR2 recovery data protects the encrypted payload.")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.tertiary)
                }
                if !encryptionKeyAvailable {
                    Text("Set up encryption passphrase in Settings > Encryption first.")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("External Volumes") {
                if volumes.isEmpty {
                    Text("No volumes configured. Add volumes in Settings.")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(volumes, id: \.persistentModelID) { volume in
                        Toggle(isOn: volumeBinding(for: volume.volumeID)) {
                            HStack {
                                Image(systemName: "externaldrive")
                                Text(volume.label)
                                    .font(Constants.Design.monoBody)
                            }
                        }
                    }
                }
            }

            Section("Cloud Storage") {
                Toggle("Upload to Backblaze B2", isOn: $settings.uploadToB2)
                    .disabled(!b2Enabled)
                    .onChange(of: settings.uploadToB2) { _, enabled in
                        if enabled {
                            if let data = UserDefaults.standard.data(forKey: B2Credentials.keychainKey),
                               let creds = try? JSONDecoder().decode(B2Credentials.self, from: data) {
                                settings.b2Credentials = creds
                            }
                        } else {
                            settings.b2Credentials = nil
                        }
                    }

                if !b2Enabled {
                    Text("Configure B2 credentials in Settings first.")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { applyDefaults() }
    }

    private func applyDefaults() {
        // Pre-select all configured volumes
        if settings.targetVolumeIDs.isEmpty && !volumes.isEmpty {
            settings.targetVolumeIDs = volumes.map(\.volumeID)
        }

        // Enable encryption if key is configured
        if !settings.encryptFiles && encryptionKeyAvailable {
            settings.encryptFiles = true
        }

        // Enable B2 upload if credentials are configured
        if !settings.uploadToB2 && b2Enabled {
            if let data = UserDefaults.standard.data(forKey: B2Credentials.keychainKey),
               let creds = try? JSONDecoder().decode(B2Credentials.self, from: data) {
                settings.uploadToB2 = true
                settings.b2Credentials = creds
            }
        }
    }

    private func volumeBinding(for volumeID: String) -> Binding<Bool> {
        Binding(
            get: { settings.targetVolumeIDs.contains(volumeID) },
            set: { isSelected in
                if isSelected {
                    settings.targetVolumeIDs.append(volumeID)
                } else {
                    settings.targetVolumeIDs.removeAll { $0 == volumeID }
                }
            }
        )
    }
}
