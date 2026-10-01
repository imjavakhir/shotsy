import CoreGraphics

/// What a swipe on the sort card means. Pure, so the gesture rules can be tested without a view.
/// Right = keep, left = mark for deletion, up (mostly vertical) = add to the swipe-up album. Down never acts.
nonisolated enum SwipeDecision: Equatable, Sendable {
    case keep, mark, album, cancel

    /// Classifies a released drag from its translation and the system's predicted end translation.
    static func classify(translation t: CGSize, predicted p: CGSize, threshold: CGFloat) -> SwipeDecision {
        if isUpward(t) && (-t.height > threshold || (isUpward(p) && -p.height > threshold * 2)) { return .album }
        if t.width > threshold || p.width > threshold * 2 { return .keep }
        if t.width < -threshold || p.width < -threshold * 2 { return .mark }
        return .cancel
    }

    /// Moving up more than sideways.
    static func isUpward(_ t: CGSize) -> Bool { t.height < 0 && -t.height > abs(t.width) }

    /// Where the card is drawn for a drag. Horizontal follows the finger and vertical is damped, except when the
    /// drag is clearly upward: then the card follows the finger up. Blended so the card never jumps.
    static func cardOffset(for t: CGSize) -> CGSize {
        let lift = t.height < 0 ? max(0, min(1, (-t.height - abs(t.width)) / 40)) : 0
        return CGSize(width: t.width, height: t.height * (0.25 + 0.75 * lift))
    }

    /// 0...1 strength of the "Album" stamp for the card's current offset.
    static func albumAmount(offset: CGSize, threshold: CGFloat) -> Double {
        guard isUpward(offset) else { return 0 }
        return Double(max(0, min(1, (-offset.height - 30) / (threshold - 30))))
    }
}
