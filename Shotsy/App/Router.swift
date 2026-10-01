import SwiftUI

enum AppTab: Hashable {
    case clean, library, albums
}

/// Why the paywall was shown; drives its headline.
enum PaywallReason: String, Identifiable {
    case dailyLimit, batchCleanup, ocrSearch, categorySuggestions, smartCollections, people, compression, settings

    var id: String { rawValue }
}

enum AppSheet: Identifiable {
    case settings
    case paywall(PaywallReason)
    case reviewDeletions

    var id: String {
        switch self {
        case .settings: "settings"
        case .paywall(let reason): "paywall-\(reason.rawValue)"
        case .reviewDeletions: "review"
        }
    }
}

struct SessionRoute: Identifiable, Hashable {
    let id: UUID
}

@Observable
final class Router {
    var tab: AppTab = .clean
    var sheet: AppSheet?
    var session: SessionRoute?
    var cleanPath = NavigationPath()
    var libraryPath = NavigationPath()
    var albumsPath = NavigationPath()

    func showPaywall(_ reason: PaywallReason) {
        // Close a running session cover first so the paywall is visible.
        sheet = .paywall(reason)
    }

    func openSession(_ id: UUID) {
        sheet = nil
        session = SessionRoute(id: id)
    }
}
