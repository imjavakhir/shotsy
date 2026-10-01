import Foundation

/// Validated in-app destinations. Deep links only navigate; they never delete, purchase, or change the library.
nonisolated enum DeepLink: Equatable, Hashable, Sendable {
    case clean
    case quick20
    case session(UUID)
    case reviewDeletions
    case library
    case albums

    /// Must match SHOTSY_URL_SCHEME in Config/Owner.xcconfig.
    static let scheme = "shotsy"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" })
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
        switch parts.first {
        case "clean": self = .clean
        case "quick20": self = .quick20
        case "review": self = .reviewDeletions
        case "library": self = .library
        case "albums": self = .albums
        case "session":
            guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
            self = .session(id)
        default:
            return nil
        }
    }

    var url: URL {
        let path: String
        switch self {
        case .clean: path = "clean"
        case .quick20: path = "quick20"
        case .session(let id): path = "session/\(id.uuidString)"
        case .reviewDeletions: path = "review"
        case .library: path = "library"
        case .albums: path = "albums"
        }
        return URL(string: "\(Self.scheme)://\(path)")!
    }
}
