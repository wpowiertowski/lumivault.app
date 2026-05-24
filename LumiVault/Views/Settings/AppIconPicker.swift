import SwiftUI

struct AppIconPicker: View {
    @Environment(AppearanceManager.self) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ForEach(AppIconVariant.allCases) { variant in
                    AppIconTile(variant: variant, isSelected: appearance.current == variant) {
                        appearance.current = variant
                    }
                }
            }
            Text("Choose an icon — the accent color matches.")
                .font(Constants.Design.monoCaption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct AppIconTile: View {
    let variant: AppIconVariant
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if let image = AppearanceManager.renderedIcon(for: variant, size: 128) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 64, height: 64)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(variant.accentColor)
                            .frame(width: 64, height: 64)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14.3, style: .continuous)
                        .strokeBorder(variant.accentColor, lineWidth: isSelected ? 2.5 : 0)
                        .padding(-3)
                )
                Text(variant.displayName)
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.primary)
                Text(variant.colorName.uppercased())
                    .font(Constants.Design.monoCaption2)
                    .tracking(1)
                    .foregroundStyle(isSelected ? variant.accentColor : .secondary)
            }
            .frame(width: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("appearance.icon.\(variant.rawValue)")
        .accessibilityLabel("\(variant.displayName) icon")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
