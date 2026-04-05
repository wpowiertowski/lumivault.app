import SwiftUI

struct MetadataInspector: View {
    let image: ImageRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // File info
                InspectorSection(title: "File") {
                    InspectorRow(label: "Name", value: image.filename)
                    InspectorRow(label: "Size", value: formattedSize)
                    InspectorRow(label: "Added", value: image.addedAt.formatted(date: .abbreviated, time: .shortened))
                }

                // Integrity
                InspectorSection(title: "Integrity") {
                    InspectorRow(label: "SHA-256", value: String(image.sha256.prefix(16)) + "...")
                    InspectorRow(label: "PAR2", value: image.par2Filename.isEmpty ? "None" : image.par2Filename)
                    if let verified = image.lastVerifiedAt {
                        InspectorRow(label: "Verified", value: verified.formatted(.relative(presentation: .named)))
                    }
                }

                // Storage locations
                InspectorSection(title: "Storage (\(image.storageLocations.count))") {
                    ForEach(image.storageLocations, id: \.volumeID) { location in
                        InspectorRow(label: location.volumeID, value: location.relativePath)
                    }
                }

                // Cloud (B2)
                InspectorSection(title: "Cloud") {
                    if let fileId = image.b2FileId, !fileId.isEmpty {
                        HStack {
                            Circle()
                                .fill(.green)
                                .frame(width: 8, height: 8)
                            Text("Uploaded to B2")
                                .font(Constants.Design.monoCaption)
                        }
                        InspectorRow(label: "File ID", value: fileId)
                    } else {
                        HStack {
                            Circle()
                                .fill(.secondary)
                                .frame(width: 8, height: 8)
                            Text("Not uploaded")
                                .font(Constants.Design.monoCaption)
                        }
                    }
                }

                // Encryption
                InspectorSection(title: "Encryption") {
                    if image.isEncrypted {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.green)
                            Text("Encrypted (AES-256-GCM)")
                                .font(Constants.Design.monoCaption)
                        }
                        if let keyId = image.encryptionKeyId {
                            InspectorRow(label: "Key ID", value: keyId)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.open")
                                .foregroundStyle(.secondary)
                            Text("Not encrypted")
                                .font(Constants.Design.monoCaption)
                        }
                    }
                }

                // Thumbnail
                InspectorSection(title: "Thumbnail") {
                    HStack {
                        Circle()
                            .fill(thumbnailColor)
                            .frame(width: 8, height: 8)
                        Text(thumbnailLabel)
                            .font(Constants.Design.monoCaption)
                    }
                }
            }
            .padding()
        }
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: image.sizeBytes, countStyle: .file)
    }

    private var thumbnailColor: Color {
        switch image.thumbnailState {
        case .pending: .orange
        case .generated: .green
        case .failed: .red
        }
    }

    private var thumbnailLabel: String {
        switch image.thumbnailState {
        case .pending: "Pending"
        case .generated: "Generated"
        case .failed: "Failed"
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Constants.Design.monoCaption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .tracking(1)
            content
            Divider()
        }
    }
}

private struct InspectorRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(Constants.Design.monoCaption)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(Constants.Design.monoCaption)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}
