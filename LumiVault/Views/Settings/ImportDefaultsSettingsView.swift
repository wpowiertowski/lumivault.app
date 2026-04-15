import SwiftUI

struct ImportDefaultsSettingsView: View {
    @AppStorage("importFormat") private var formatRaw = ImageFormat.original.rawValue
    @AppStorage("importJpegQuality") private var jpegQuality = 0.85
    @AppStorage("importMaxDimension") private var maxDimensionRaw = 0 // 0 = original
    @AppStorage("importGeneratePAR2") private var generatePAR2 = true
    @AppStorage("importDetectNearDuplicates") private var detectNearDuplicates = true

    private var format: Binding<ImageFormat> {
        Binding(
            get: { ImageFormat(rawValue: formatRaw) ?? .original },
            set: { formatRaw = $0.rawValue }
        )
    }

    private var maxDimension: Binding<MaxDimension> {
        Binding(
            get: { maxDimensionRaw == 0 ? .original : .capped(maxDimensionRaw) },
            set: {
                switch $0 {
                case .original: maxDimensionRaw = 0
                case .capped(let px): maxDimensionRaw = px
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("Image Format") {
                Picker("Format", selection: format) {
                    ForEach(ImageFormat.allCases, id: \.self) { fmt in
                        Text(fmt.rawValue).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)
                .font(Constants.Design.monoBody)

                if format.wrappedValue == .jpeg || format.wrappedValue == .heif {
                    HStack {
                        Text("Quality")
                            .font(Constants.Design.monoBody)
                        Slider(value: $jpegQuality, in: 0.1...1.0, step: 0.05)
                        Text("\(Int(jpegQuality * 100))%")
                            .font(Constants.Design.monoCaption)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }

                Picker("Max dimension", selection: maxDimension) {
                    ForEach(MaxDimension.presets, id: \.self) { dim in
                        Text(dim.label).tag(dim)
                    }
                }
                .font(Constants.Design.monoBody)

                if format.wrappedValue != .original || maxDimension.wrappedValue != .original {
                    Text("Images will be converted during import. Originals in Photos are not modified.")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Processing") {
                Toggle("Generate PAR2 error correction", isOn: $generatePAR2)
                    .accessibilityIdentifier("importDefaults.par2")
                Toggle("Detect near-duplicate images", isOn: $detectNearDuplicates)
                    .accessibilityIdentifier("importDefaults.nearDupe")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
