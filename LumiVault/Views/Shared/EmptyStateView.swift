import SwiftUI

struct EmptyStateView: View {
    let message: String

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
