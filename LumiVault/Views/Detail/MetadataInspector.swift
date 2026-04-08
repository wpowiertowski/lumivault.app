import SwiftUI
import MapKit

struct MetadataInspector: View {
    let image: ImageRecord
    var exif: EXIFData?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // File info
                InspectorSection(title: "File") {
                    InspectorRow(label: "Name", value: image.filename)
                    InspectorRow(label: "Size", value: formattedSize)
                    InspectorRow(label: "Added", value: image.addedAt.formatted(date: .abbreviated, time: .shortened))
                }

                // EXIF — Camera & Capture
                if let exif, hasExifContent(exif) {
                    InspectorSection(title: "Camera") {
                        if let make = exif.cameraMake {
                            InspectorRow(label: "Make", value: make)
                        }
                        if let model = exif.cameraModel {
                            InspectorRow(label: "Model", value: model)
                        }
                        if let lens = exif.lensModel {
                            InspectorRow(label: "Lens", value: lens)
                        }
                        if let software = exif.software {
                            InspectorRow(label: "Software", value: software)
                        }
                    }

                    if hasExposureData(exif) {
                        InspectorSection(title: "Exposure") {
                            if let shutter = exif.exposureString {
                                InspectorRow(label: "Shutter", value: shutter)
                            }
                            if let aperture = exif.fNumberString {
                                InspectorRow(label: "Aperture", value: aperture)
                            }
                            if let iso = exif.isoString {
                                InspectorRow(label: "ISO", value: iso)
                            }
                            if let fl = exif.focalLengthString {
                                InspectorRow(label: "Focal Length", value: fl)
                            }
                        }
                    }

                    if let dims = exif.dimensionsString {
                        InspectorSection(title: "Image") {
                            InspectorRow(label: "Dimensions", value: dims)
                            if let cs = exif.colorSpace {
                                InspectorRow(label: "Color Space", value: cs)
                            }
                            if let depth = exif.bitDepth {
                                InspectorRow(label: "Bit Depth", value: "\(depth) bit")
                            }
                        }
                    }

                    if let date = exif.dateTaken {
                        InspectorSection(title: "Date Taken") {
                            InspectorRow(label: "Original", value: date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
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

                // GPS Map
                if let exif, let coordinate = exif.coordinate {
                    InspectorSection(title: "Location") {
                        if let coords = exif.coordinateString {
                            InspectorRow(label: "Coordinates", value: coords)
                        }
                        if let alt = exif.altitudeString {
                            InspectorRow(label: "Altitude", value: alt)
                        }
                    }

                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    ))) {
                        Marker(image.filename, coordinate: coordinate)
                    }
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
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

    private func hasExifContent(_ exif: EXIFData) -> Bool {
        exif.cameraMake != nil || exif.cameraModel != nil || exif.lensModel != nil ||
        exif.exposureTime != nil || exif.pixelWidth != nil || exif.dateTaken != nil
    }

    private func hasExposureData(_ exif: EXIFData) -> Bool {
        exif.exposureTime != nil || exif.fNumber != nil || exif.iso != nil || exif.focalLength != nil
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
