import SwiftUI

struct AlbumDeletionSheet: View {
    let progress: DeletionProgress
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            if progress.phase == .complete {
                Image(systemName: progress.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(progress.errors.isEmpty ? .green : .orange)

                Text("Deletion Complete")
                    .font(Constants.Design.monoHeadline)

                if !progress.errors.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(progress.errors, id: \.self) { error in
                                Text(error)
                                    .font(Constants.Design.monoCaption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)

                Text(progress.phase.rawValue)
                    .font(Constants.Design.monoBody)
                    .foregroundStyle(.secondary)

                if progress.totalItems > 0 {
                    Text("\(progress.processedItems) / \(progress.totalItems)")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}
