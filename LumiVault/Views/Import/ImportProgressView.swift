import SwiftUI

struct ImportProgressView: View {
    let progress: ImportProgress

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: progress.fraction) {
                Text("Importing...")
                    .font(Constants.Design.monoBody)
            }

            HStack(spacing: 16) {
                StatLabel(label: "Processed", value: "\(progress.completed)/\(progress.total)")
                if progress.deduplicated > 0 {
                    StatLabel(label: "Duplicates", value: "\(progress.deduplicated)")
                }
                if progress.failed > 0 {
                    StatLabel(label: "Failed", value: "\(progress.failed)")
                        .foregroundStyle(.red)
                }
            }
            .font(Constants.Design.monoCaption)
        }
        .padding()
    }
}

private struct StatLabel: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .fontWeight(.medium)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}
