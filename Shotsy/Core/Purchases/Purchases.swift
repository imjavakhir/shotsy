import RevenueCat
import SwiftUI

/// What the app needs from RevenueCat's `CustomerInfo`, so entitlement rules are testable without the SDK.
nonisolated struct EntitlementSnapshot: Equatable, Sendable {
    /// The owner's RevenueCat entitlement ("pro") is active.
    var isActive: Bool
    var productIdentifier: String?
    /// nil for non-consumables (lifetime).
    var expirationDate: Date?
    var activeSubscriptions: Set<String> = []
}

nonisolated enum Entitlement: Equatable, Sendable {
    case none
    case weekly(expires: Date?)
    case lifetime(alsoHasWeekly: Bool)

    var isPro: Bool { self != .none }
}

nonisolated enum EntitlementResolver {
    /// RevenueCat decides whether the entitlement is active (it handles grace periods, refunds and expiry
    /// server-side). Lifetime wins over weekly. An active weekly alongside lifetime is surfaced, since buying
    /// Lifetime doesn't cancel it.
    static func resolve(_ snapshot: EntitlementSnapshot?) -> Entitlement {
        guard let snapshot, snapshot.isActive else { return .none }
        let hasWeekly = snapshot.activeSubscriptions.contains(OwnerConfig.weeklyProductID)
        if snapshot.productIdentifier == OwnerConfig.lifetimeProductID || snapshot.expirationDate == nil {
            return .lifetime(alsoHasWeekly: hasWeekly)
        }
        return .weekly(expires: snapshot.expirationDate)
    }
}

nonisolated enum PurchaseResult: Equatable, Sendable {
    case success, cancelled, pending, failed(String)
}

/// RevenueCat is the single purchase and entitlement system for Shotsy Pro. There is no local premium flag:
/// `entitlement` always comes from RevenueCat's `CustomerInfo` (cached by the SDK, so access works offline).
@Observable
final class PurchaseStore {
    enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    private(set) var weeklyPackage: Package?
    private(set) var lifetimePackage: Package?
    private(set) var loadState: LoadState = .idle
    private(set) var entitlement: Entitlement = .none
    private(set) var weeklyWillRenew = false
    /// App Store reported a billing problem; access continues through Apple's grace period if enabled.
    private(set) var billingIssue = false
    private(set) var hasCheckedEntitlements = false

    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    /// Called when the entitlement changes. `initial` is true for the first result after launch.
    @ObservationIgnored var onEntitlementChange: ((_ entitlement: Entitlement, _ initial: Bool) -> Void)?

    var isPro: Bool { entitlement.isPro }
    /// False until the owner adds a RevenueCat API key in OwnerConfig.
    var isConfigured: Bool { OwnerConfig.revenueCatAPIKey != nil }

    func start() {
        guard updatesTask == nil, let key = OwnerConfig.revenueCatAPIKey else {
            if !isConfigured { loadState = .failed(String(localized: "Purchases aren't set up in this build yet.")) }
            return
        }
        #if DEBUG
        Purchases.logLevel = .info
        #else
        Purchases.logLevel = .warn
        #endif
        Purchases.configure(withAPIKey: key)
        updatesTask = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                self?.apply(info)
            }
        }
        Task { await loadOfferings() }
    }

    func loadOfferings() async {
        guard Purchases.isConfigured else {
            loadState = .failed(String(localized: "Purchases aren't set up in this build yet."))
            return
        }
        loadState = .loading
        // The App Store sometimes returns no products on the first request (new products, sandbox hiccups),
        // so retry a couple of times before showing an error. Users see a short message, never SDK details.
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(Double(attempt) * 1.5)) }
            do {
                let offerings = try await Purchases.shared.offerings()
                let offering = OwnerConfig.revenueCatOfferingID.flatMap { offerings[$0] } ?? offerings.current
                let packages = offering?.availablePackages ?? []
                weeklyPackage = offering?.weekly
                    ?? packages.first { $0.storeProduct.productIdentifier == OwnerConfig.weeklyProductID }
                lifetimePackage = offering?.lifetime
                    ?? packages.first { $0.storeProduct.productIdentifier == OwnerConfig.lifetimeProductID }
                if weeklyPackage != nil || lifetimePackage != nil {
                    loadState = .loaded
                    return
                }
            } catch {
                #if DEBUG
                print("Shotsy offerings attempt \(attempt + 1) failed: \(error)")
                #endif
            }
        }
        loadState = .failed(String(localized: "Plans aren't available right now."))
    }

    func purchase(_ package: Package) async -> PurchaseResult {
        guard Purchases.isConfigured else { return .failed(String(localized: "Purchases aren't set up in this build yet.")) }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return .cancelled }
            apply(result.customerInfo)
            return isPro ? .success : .failed(String(localized: "The purchase finished, but Pro isn't active yet. Try Restore Purchases."))
        } catch let error as RevenueCat.ErrorCode {
            switch error {
            case .purchaseCancelledError: return .cancelled
            case .paymentPendingError: return .pending
            default: return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Restore Purchases.
    func restore() async -> PurchaseResult {
        guard Purchases.isConfigured else { return .failed(String(localized: "Purchases aren't set up in this build yet.")) }
        do {
            apply(try await Purchases.shared.restorePurchases())
            return isPro ? .success : .failed(String(localized: "No purchases to restore for this Apple Account."))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func refreshEntitlements() async {
        guard Purchases.isConfigured, let info = try? await Purchases.shared.customerInfo() else { return }
        apply(info)
    }

    private func apply(_ info: CustomerInfo) {
        let e = info.entitlements[OwnerConfig.revenueCatEntitlementID]
        let snapshot = e.map {
            EntitlementSnapshot(isActive: $0.isActive, productIdentifier: $0.productIdentifier,
                                expirationDate: $0.expirationDate, activeSubscriptions: info.activeSubscriptions)
        }
        weeklyWillRenew = e?.willRenew ?? false
        billingIssue = e?.billingIssueDetectedAt != nil
        let initial = !hasCheckedEntitlements
        hasCheckedEntitlements = true
        let new = EntitlementResolver.resolve(snapshot)
        if new != entitlement {
            entitlement = new
            onEntitlementChange?(new, initial)
        }
    }
}
