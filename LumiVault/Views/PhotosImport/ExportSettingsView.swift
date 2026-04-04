import SwiftUI
import SwiftData

struct ExportSettingsView: View {
    @Binding var settings: ExportSettings
    @Query private var volumes: [VolumeRecord]
    @AppStorage("b2Enabled") private var b2Enabled = false

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

                if !b2Enabled {
                    Text("Configure B2 credentials in Settings first.")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
