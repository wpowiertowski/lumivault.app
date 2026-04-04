import SwiftUI

struct EmptyStateView: View {
    let message: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Text("LUMIVAULT")
                .font(.caption)
                .fontWeight(.semibold)
                .tracking(2)
                .foregroundStyle(Constants.Design.accentColor)

            Text(message)
                .font(Constants.Design.monoHeadline)
                .foregroundStyle(.secondary)

            if let actionLabel, let action {
                Button(action: action) {
                    Label(actionLabel, systemImage: "photo.badge.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
