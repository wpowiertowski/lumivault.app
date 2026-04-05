import SwiftUI
import StoreKit

struct SupportSettingsView: View {
    @State private var products: [Product] = []
    @State private var isLoading = true
    @State private var purchaseError: String?
    @State private var thankYou = false

    private static let productIDs = [
        "app.lumivault.tip.small",
        "app.lumivault.tip.medium",
        "app.lumivault.tip.large",
        "app.lumivault.tip.generous"
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Constants.Design.accentColor)

                    Text("Support LumiVault")
                        .font(Constants.Design.monoHeadline)

                    Text("LumiVault is built with care as an independent app. If you find it useful for protecting your photo library, consider leaving a tip to support ongoing development.")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .padding(.top, 8)

                if thankYou {
                    Label("Thank you for your support!", systemImage: "heart.fill")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.pink)
                        .padding(.vertical, 4)
                }

                Divider()
                    .padding(.horizontal, 40)

                // Tip options
                if isLoading {
                    ProgressView()
                        .padding()
                } else if products.isEmpty {
                    // Fallback when products aren't configured in App Store Connect yet
                    VStack(spacing: 12) {
                        Text("Tip jar coming soon")
                            .font(Constants.Design.monoCaption)
                            .foregroundStyle(.secondary)
                        Text("In-app purchase products are being set up. Check back in a future update.")
                            .font(Constants.Design.monoCaption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .padding()
                } else {
                    VStack(spacing: 0) {
                        ForEach(products.sorted(by: { $0.price < $1.price })) { product in
                            TipRow(product: product) {
                                await purchase(product)
                            }
                            if product.id != products.sorted(by: { $0.price < $1.price }).last?.id {
                                Divider()
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 20)
                }

                if let error = purchaseError {
                    Text(error)
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                }

                Spacer(minLength: 8)
            }
            .padding(.vertical, 8)
        }
        .task { await loadProducts() }
    }

    private func loadProducts() async {
        isLoading = true
        do {
            products = try await Product.products(for: Self.productIDs)
        } catch {
            purchaseError = "Could not load products: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func purchase(_ product: Product) async {
        purchaseError = nil
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    thankYou = true
                case .unverified:
                    purchaseError = "Purchase could not be verified."
                }
            case .userCancelled:
                break
            case .pending:
                purchaseError = "Purchase is pending approval."
            @unknown default:
                break
            }
        } catch {
            purchaseError = "Purchase failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Tip Row

private struct TipRow: View {
    let product: Product
    let onPurchase: () async -> Void
    @State private var isPurchasing = false

    private var icon: String {
        switch product.id {
        case "app.lumivault.tip.small": "cup.and.saucer"
        case "app.lumivault.tip.medium": "mug"
        case "app.lumivault.tip.large": "takeoutbag.and.cup.and.straw"
        case "app.lumivault.tip.generous": "star.circle"
        default: "heart"
        }
    }

    private var subtitle: String {
        switch product.id {
        case "app.lumivault.tip.small": "A small token of appreciation"
        case "app.lumivault.tip.medium": "Fuel for late-night coding sessions"
        case "app.lumivault.tip.large": "Keeps the backups flowing"
        case "app.lumivault.tip.generous": "Above and beyond — thank you!"
        default: "Thank you for your support"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Constants.Design.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(product.displayName)
                    .font(Constants.Design.monoBody)
                Text(subtitle)
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                isPurchasing = true
                Task {
                    await onPurchase()
                    isPurchasing = false
                }
            } label: {
                if isPurchasing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 60)
                } else {
                    Text(product.displayPrice)
                        .font(Constants.Design.monoCaption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Constants.Design.accentColor.opacity(0.15))
                        .foregroundStyle(Constants.Design.accentColor)
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(isPurchasing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
