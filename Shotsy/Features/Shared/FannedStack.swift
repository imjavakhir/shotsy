import Photos
import SwiftUI

/// Where each card of a fanned stack sits, left to right. Pure, so it's testable.
nonisolated enum FannedLayout {
    struct Slot: Equatable, Sendable {
        /// Degrees, rotated around the card's bottom center.
        var angle: Double
        var x: Double
        var y: Double
    }

    static let maxCards = 4

    /// Up to four cards, fanned like a hand: outer cards tilt more, sit further out and slightly lower.
    static func slots(count: Int, spread: Double) -> [Slot] {
        let angles: [Double] = switch min(count, maxCards) {
        case ...0: []
        case 1: [0]
        case 2: [-5, 5]
        case 3: [-8, 0, 8]
        default: [-8, -3, 3, 8]
        }
        return angles.map { angle in
            let t = angle / 8
            return Slot(angle: angle, x: t * spread, y: abs(t) * 4)
        }
    }
}

/// A month's or category's first photos, overlapping and rotated like a hand of cards.
/// The first asset is the top card, on the right. Decorative: hidden from VoiceOver.
/// Takes either resolved assets or identifiers, which it resolves off the main thread.
struct FannedStack: View {
    private let ids: [String]?
    private let given: [PHAsset]
    private let cardSize: CGSize
    private let spread: CGFloat
    private let cornerRadius: CGFloat
    @Environment(PhotoLibrary.self) private var library
    @State private var loaded: [PHAsset] = []

    init(assets: [PHAsset], cardSize: CGSize = CGSize(width: 64, height: 84), spread: CGFloat = 30,
         cornerRadius: CGFloat = 10) {
        self.ids = nil
        self.given = assets
        self.cardSize = cardSize
        self.spread = spread
        self.cornerRadius = cornerRadius
    }

    init(ids: [String], cardSize: CGSize = CGSize(width: 64, height: 84), spread: CGFloat = 30,
         cornerRadius: CGFloat = 10) {
        self.ids = Array(ids.prefix(FannedLayout.maxCards))
        self.given = []
        self.cardSize = cardSize
        self.spread = spread
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        let shown = Array((ids == nil ? given : loaded).prefix(FannedLayout.maxCards))
        let slots = FannedLayout.slots(count: max(shown.count, 3), spread: spread)
        ZStack {
            if shown.isEmpty {
                // Still loading: blank cards in the same shape so the layout doesn't jump.
                ForEach(slots.indices, id: \.self) { i in
                    card { Color.appChip }.placed(slots[i])
                }
            } else {
                let placed = FannedLayout.slots(count: shown.count, spread: spread)
                ForEach(Array(shown.enumerated()), id: \.element.localIdentifier) { i, asset in
                    card { AssetThumbnail(asset: asset, targetSide: max(cardSize.width, cardSize.height)) }
                        .placed(placed[shown.count - 1 - i])
                        .zIndex(Double(shown.count - i))
                }
            }
        }
        // Room for the outer cards' tilt and offset.
        .frame(width: cardSize.width + spread * 2 + cardSize.height * 0.15,
               height: cardSize.height + 10)
        .accessibilityHidden(true)
        .task(id: LoadKey(ids: ids, changeCount: library.changeCount)) { await load() }
    }

    nonisolated private struct LoadKey: Equatable {
        var ids: [String]?
        var changeCount: Int
    }

    private func load() async {
        guard let ids else { return }
        let canRead = library.access.canRead
        let map = await BackgroundFetch.run { canRead ? BackgroundFetch.assets(for: ids) : [:] }
        guard !Task.isCancelled else { return }
        loaded = ids.compactMap { map[$0] }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.appSurface, lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.16), radius: 3, x: 0, y: 2)
    }
}

private extension View {
    func placed(_ slot: FannedLayout.Slot) -> some View {
        rotationEffect(.degrees(slot.angle), anchor: .bottom)
            .offset(x: slot.x, y: slot.y)
    }
}
