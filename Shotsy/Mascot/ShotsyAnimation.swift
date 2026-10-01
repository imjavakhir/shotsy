import Lottie
import SwiftUI

/// Lottie clips bundled from brand/lottie. Each has a `-badge` variant.
enum ShotsyClip: String {
    case idle = "shotsy-idle"
    case hello = "shotsy-hello"
    case whoa = "shotsy-whoa"
    case tidy = "shotsy-tidy"
    case wink = "shotsy-wink"

    func name(badge: Bool) -> String { badge ? rawValue + "-badge" : rawValue }
}

/// Animated Shotsy. Plays once on appear (or loops), and shows the final pose under Reduce Motion.
/// Brand rule: only one animated Shotsy on screen at a time.
struct ShotsyAnimation: View {
    let clip: ShotsyClip
    var badge = false
    var loop = false
    /// Optional corner recolor, e.g. white corners on a dark card.
    var cornerColor: UIColor?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Brand rule: the badge variant on dark backgrounds.
        LottieView(animation: .named(clip.name(badge: badge || (colorScheme == .dark && cornerColor == nil))))
            .playbackMode(reduceMotion
                ? .paused(at: .progress(1))
                : .playing(.fromProgress(0, toProgress: 1, loopMode: loop ? .loop : .playOnce)))
            .configure { view in
                if let cornerColor {
                    view.setValueProvider(
                        ColorValueProvider(cornerColor.lottieColorValue),
                        keypath: AnimationKeypath(keypath: "**.BracketStroke.Color")
                    )
                }
            }
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

#Preview {
    VStack {
        ShotsyAnimation(clip: .idle, loop: true).frame(width: 160)
        ShotsyAnimation(clip: .whoa, badge: true).frame(width: 160)
    }
}
