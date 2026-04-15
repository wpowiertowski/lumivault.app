import SwiftUI
import SwiftData

struct ImportSettingsView: View {
    @Binding var settings: ImportSettings
    var showAlbumDetails: Bool = true
    @Query private var volumes: [VolumeRecord]
    @AppStorage("b2Enabled") private var b2Enabled = false
    @AppStorage("encryptionEnabled") private var encryptionEnabled = false

    @AppStorage("importFormat") private var defaultFormat = ImageFormat.original.rawValue
    @AppStorage("importJpegQuality") private var defaultJpegQuality = 0.85
    @AppStorage("importMaxDimension") private var defaultMaxDimension = 0
    @AppStorage("importGeneratePAR2") private var defaultGeneratePAR2 = true
    @AppStorage("importDetectNearDuplicates") private var defaultDetectNearDuplicates = true

    private var encryptionKeyAvailable: Bool {
        encryptionEnabled && EncryptionService.storedKeyId() != nil
    }

    var body: some View {
        Form {
            if showAlbumDetails {
                Section("Album Details") {
                    TextField("Album Name", text: $settings.albumName)
                        .font(Constants.Design.monoBody)
                        .accessibilityIdentifier("importSettings.albumName")

                    HStack(spacing: 12) {
                        TextField("Year", text: $settings.year)
                            .frame(minWidth: 70)
                            .accessibilityIdentifier("importSettings.year")
                        TextField("Month", text: $settings.month)
                            .frame(minWidth: 55)
                            .accessibilityIdentifier("importSettings.month")
                        TextField("Day", text: $settings.day)
                            .frame(minWidth: 55)
                            .accessibilityIdentifier("importSettings.day")
                    }
                    .font(Constants.Design.monoBody)
                }
            }

            Section("Image Format") {
                Picker("Format", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases, id: \.self) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .font(Constants.Design.monoBody)

                if settings.imageFormat == .jpeg || settings.imageFormat == .heif {
                    HStack {
                        Text("Quality")
                            .font(Constants.Design.monoBody)
                        Slider(value: $settings.jpegQuality, in: 0.1...1.0, step: 0.05)
                        Text("\(Int(settings.jpegQuality * 100))%")
                            .font(Constants.Design.monoCaption)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }

                Picker("Max dimension", selection: $settings.maxDimension) {
                    ForEach(MaxDimension.presets, id: \.self) { dim in
                        Text(dim.label).tag(dim)
                    }
                }
                .font(Constants.Design.monoBody)

                if settings.imageFormat != .original || settings.maxDimension != .original {
                    Text("Images will be converted during import. Originals in Photos are not modified.")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Recovery") {
                Toggle("Generate PAR2 error correction", isOn: $settings.generatePAR2)
                    .accessibilityIdentifier("importSettings.par2")
            }

            Section("Deduplication") {
                Toggle("Detect near-duplicate images", isOn: $settings.detectNearDuplicates)
                    .accessibilityIdentifier("importSettings.nearDupe")
                Text("Uses perceptual hashing to flag visually similar images during import.")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.tertiary)
            }

            Section("Encryption") {
                Toggle("Encrypt files at rest", isOn: $settings.encryptFiles)
                    .disabled(!encryptionKeyAvailable)
                    .accessibilityIdentifier("importSettings.encrypt")
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
                    .accessibilityIdentifier("importSettings.b2Upload")
                    .onChange(of: settings.uploadToB2) { _, enabled in
                        if enabled {
                            if let data = UserDefaults.standard.data(forKey: B2Credentials.defaultsKey),
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
        // Apply saved import defaults
        settings.imageFormat = ImageFormat(rawValue: defaultFormat) ?? .original
        settings.jpegQuality = defaultJpegQuality
        settings.maxDimension = defaultMaxDimension == 0 ? .original : .capped(defaultMaxDimension)
        settings.generatePAR2 = defaultGeneratePAR2
        settings.detectNearDuplicates = defaultDetectNearDuplicates

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
            if let data = UserDefaults.standard.data(forKey: B2Credentials.defaultsKey),
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
