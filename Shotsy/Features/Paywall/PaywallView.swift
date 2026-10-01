import RevenueCat
import StoreKit
import SwiftUI

/// Two plans, both unlock the same Shotsy Pro (RevenueCat entitlement). Prices are the App Store's
/// localized prices as delivered through RevenueCat (`localizedPriceString`).
struct PaywallView: View {
    let reason: PaywallReason

    enum Plan { case lifetime, weekly }

    @Environment(PurchaseStore.self) private var purchases
    @Environment(\.dismiss) private var dismiss
    @State private var plan: Plan = .lifetime
    @State private var working = false
    @State private var message: String?
    @State private var manageSubscriptions = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.l) {
                    ShotsyAnimation(clip: .wink, badge: true)
                        .frame(width: 110, height: 110)
                        .padding(.top, Space.s)
                    Text(headline)
                        .font(.display(26, relativeTo: .title))
                        .foregroundStyle(Color.appText)
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: Space.s) {
                        benefit("infinity", "Sort without limits", "Swipe as much as you like, every day.")
                        benefit("square.stack.3d.down.right", "Clean up in one tap",
                                "Clear similar photos, duplicates, and blurry shots at once. Shrink big videos too.")
                        benefit("text.magnifyingglass", "Find any screenshot",
                                "Search the words inside your screenshots and keep them sorted for you.")
                    }
                    .card()

                    if case .lifetime = purchases.entitlement {
                        Label("You have Shotsy Pro for life. Thank you!", systemImage: "checkmark.seal.fill")
                            .font(.appHeadline).foregroundStyle(Color.appSuccess)
                    } else {
                        plans
                    }

                    if let message {
                        Text(message).font(.appFootnote).foregroundStyle(Color.appSecondaryText).multilineTextAlignment(.center)
                    }

                    footer
                }
                .padding(.horizontal, Space.page)
                .padding(.bottom, Space.xl)
            }
            .softAppBar()
            .pageBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .manageSubscriptionsSheet(isPresented: $manageSubscriptions)
            .task { if purchases.loadState != .loaded { await purchases.loadOfferings() } }
        }
    }

    private var headline: LocalizedStringKey {
        switch reason {
        case .dailyLimit: "Keep going. No limits."
        case .batchCleanup: "Clean up in one tap"
        case .ocrSearch, .categorySuggestions: "Find any screenshot"
        case .smartCollections: "Make all the collections"
        case .people: "Your whole library, sorted"
        case .compression: "Shrink big videos"
        case .settings: "Meet Shotsy Pro"
        }
    }

    @ViewBuilder private var plans: some View {
        switch purchases.loadState {
        case .failed(let error):
            VStack(spacing: Space.s) {
                Notice(kind: .error, text: LocalizedStringKey(error))
                if purchases.isConfigured {
                    Button("Try again") { Task { await purchases.loadOfferings() } }.buttonStyle(.secondary)
                }
            }
        case .loaded:
            VStack(spacing: Space.s) {
                if let lifetime = purchases.lifetimePackage {
                    PlanCard(title: "Lifetime", price: lifetime.localizedPriceString, detail: "Pay once, yours forever",
                             selected: plan == .lifetime, badge: "Best value") { plan = .lifetime }
                }
                if let weekly = purchases.weeklyPackage {
                    PlanCard(title: "Weekly", price: "\(weekly.localizedPriceString)/week",
                             detail: "Flexible, cancel anytime", selected: plan == .weekly) { plan = .weekly }
                }
                if plan == .lifetime, case .weekly = purchases.entitlement {
                    Text("Your weekly plan keeps renewing until you cancel it.")
                        .font(.appFootnote).foregroundStyle(Color.appSecondaryText).multilineTextAlignment(.center)
                    Button("Manage subscription") { manageSubscriptions = true }.font(.appFootnote)
                }
                Button {
                    Task { await buy() }
                } label: {
                    if working { ProgressView().tint(.white) } else {
                        Text(plan == .lifetime ? "Unlock Lifetime" : "Subscribe Weekly")
                    }
                }
                .buttonStyle(.primary)
                .disabled(working || (plan == .weekly && purchases.entitlement != .none))
                Text(plan == .lifetime ? "One payment. No subscription." : "Renews weekly. Cancel anytime in your Apple Account.")
                    .font(.appCaption).foregroundStyle(Color.appSecondaryText).multilineTextAlignment(.center)
            }
        default:
            ProgressView().frame(minHeight: 120)
        }
    }

    private var footer: some View {
        HStack(spacing: Space.m) {
            Button("Restore Purchases") {
                Task {
                    working = true
                    let result = await purchases.restore()
                    working = false
                    switch result {
                    case .success: dismiss()
                    case .failed(let m): message = m
                    default: break
                    }
                }
            }
            Link("Terms", destination: OwnerConfig.effectiveTermsURL)
            if let privacy = OwnerConfig.privacyPolicyURL { Link("Privacy", destination: privacy) }
        }
        .font(.appFootnote)
        .frame(minHeight: Space.minTap)
    }

    private func benefit(_ icon: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: icon).foregroundStyle(Color.appAccent).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.appHeadline).foregroundStyle(Color.appText)
                Text(text).font(.appFootnote).foregroundStyle(Color.appSecondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func buy() async {
        guard let package = plan == .lifetime ? purchases.lifetimePackage : purchases.weeklyPackage else { return }
        working = true
        message = nil
        let result = await purchases.purchase(package)
        working = false
        switch result {
        case .success: dismiss()
        case .cancelled: break
        case .pending: message = String(localized: "Waiting for approval. You'll get Pro as soon as it's approved.")
        case .failed(let m): message = m
        }
    }
}

private struct PlanCard: View {
    let title: LocalizedStringKey
    let price: String
    let detail: LocalizedStringKey
    let selected: Bool
    /// Short factual label, e.g. "Best value". Never a made-up discount.
    var badge: LocalizedStringKey?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(Color.appAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.appHeadline).foregroundStyle(Color.appText)
                    Text(detail).font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                }
                Spacer()
                Text(price).font(.display(18, relativeTo: .headline)).foregroundStyle(Color.appText)
            }
            .padding(Space.m)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(selected ? Color.appAccentFill : Color.appLine, lineWidth: selected ? 2.5 : 1))
            .overlay(alignment: .topTrailing) {
                if let badge {
                    // Ink on mint: brand colors with strong contrast in light and dark.
                    Text(badge)
                        .font(.onest(12, .bold, relativeTo: .caption))
                        .textCase(.uppercase)
                        .foregroundStyle(Brand.ink)
                        .padding(.horizontal, Space.xs)
                        .padding(.vertical, 4)
                        .background(Brand.mint, in: Capsule())
                        .offset(x: -Space.m, y: -11)
                }
            }
            .padding(.top, badge == nil ? 0 : 6)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
