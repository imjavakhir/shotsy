import Foundation

/// Owner-provided values used in code. Build-time values (bundle ID, team, App Group, URL scheme)
/// live in Config/Owner.xcconfig. Everything marked EXAMPLE must be replaced before release.
nonisolated enum OwnerConfig {
    /// RevenueCat public Apple API key (Project settings → API keys, starts with "appl_"). `nil` = purchases off:
    /// the paywall shows "not set up" and everything stays on the free tier.
    static let revenueCatAPIKey: String? = "appl_GgXaYbXjLPcHNqVwycfBfbOfYZu"
    /// RevenueCat entitlement that both products unlock.
    static let revenueCatEntitlementID = "shotsy_pro"
    /// Offering to show. `nil` uses the offering marked Current in the RevenueCat dashboard.
    static let revenueCatOfferingID: String? = nil

    // App Store Connect products (created 2026-09-28): weekly auto-renewable subscription in group "Shotsy Pro"
    // at USD 1.99, and a non-consumable at USD 19.99. Attach both to the RevenueCat entitlement and offering.
    static let weeklyProductID = "com.solo.shotsy.pro.weekly"
    static let lifetimeProductID = "com.solo.shotsy.pro.lifetime"
    static var productIDs: [String] { [lifetimeProductID, weeklyProductID] }

    /// Your hosted privacy policy. `nil` until you provide one; the app then shows its built-in privacy summary only.
    static let privacyPolicyURL: URL? = URL(string: "https://sites.google.com/view/shotsy")
    /// Custom Terms of Use. `nil` uses Apple's Standard EULA below.
    static let termsURL: URL? = nil
    /// Support contact, e.g. "support@yourdomain.com". `nil` hides the row.
    static let supportEmail: String? = nil

    /// Apple's Standard Licensed Application End User License Agreement.
    static let appleStandardEULA = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    static var effectiveTermsURL: URL { termsURL ?? appleStandardEULA }
}

/// Free vs Pro limits. One place to change the product decision.
nonisolated struct Policy: Sendable, Equatable {
    /// Unique review decisions per local calendar day for free users (sorting, Quick 20, and every other entry point).
    var freeDailyReviews = 30
    /// Saved Smart Collections for free users.
    var freeSmartCollections = 1
    /// Quick 20 session size.
    var quickSessionSize = 20

    static let current = Policy()
}
