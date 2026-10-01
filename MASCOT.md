# Shotsy — logo & mascot kit

## Who Shotsy is
Shotsy is the little crop frame that lives in your camera roll. The four corners are the screenshot crop handles every iPhone user
knows; inside them is a face. The mascot and the logo are the same thing: in the wordmark, Shotsy's face is the "o".

- **Personality:** curious, tidy, a bit dramatic about clutter, loyal. Collects everything you screenshot and never loses a thing.
- **Voice:** first person, short, warm. "I'll sort them." "Found it." "All tidy." Never mean, never nags, never guilt-trips
  about how many screenshots you have — the shock is played for fun, then Shotsy helps.
- **Doesn't:** talk in long sentences, use emoji, appear more than once per screen, get sad or angry.
- **Name:** Shotsy (same as the app), because the face *is* the "o" in the logo.

## Moods and when to use them
| Mood | Face | Use it for |
|---|---|---|
| **Hi** | round eyes with shine, small smile | default: headers, empty states, idle loop |
| **Whoa** | corners spread out, big eyes, "o" mouth | big moments: first scan, "3,482 screenshots", big counts |
| **Tidy** | closed happy eyes, big smile, mint sparkle | success: after cleanup, all sorted, streaks |
| **Wink** | one eye closed, head tilt | sharing: recap card, invite friends, promos |

Two color versions of everything:
- **Light:** grape corners `#5B3FD9` on light backgrounds (paper `#F5F3FC`, white).
- **Badge:** white corners on a lilac `#A794FF` rounded square (the app icon look). Use on dark or busy backgrounds.
Face is always ink `#1B1633`, blush `#FFA8CF`, sparkle mint `#43D9A3`. Never recolor the face; never put white text on lilac.

Clear space around the icon or mascot: at least 20% of its width. Minimum size: 24pt (drop the blush below 44pt).

## Files
```
svg/            static, for the app, App Store, web, print
  app-icon-1024.svg        square master for the App Store icon (iOS rounds it)
  app-icon-rounded.svg     rounded version for marketing
  logo-lockup.svg          icon + wordmark
  wordmark.svg / wordmark-white.svg   outlined (no font needed)
  mascot-{hi,whoa,tidy,wink}.svg        light version
  mascot-{hi,whoa,tidy,wink}-badge.svg  badge version
lottie/         animations for the iOS app (512×512, 60 fps, ~11 KB each)
  shotsy-idle(.json)   3.0s  loop  gentle bob + blink
  shotsy-hello         0.9s  once  pops in, settles, blinks
  shotsy-whoa          1.2s  once  corners burst out, eyes grow, "o" mouth (ends in Whoa pose)
  shotsy-tidy          1.6s  once  squash, jump, land, sparkle spins in (ends in Tidy pose)
  shotsy-wink          1.1s  once  head tilt + wink, back to Hi
  each has a -badge variant
animated-svg/   CSS-animated idle loop for the website/landing page (respects reduced motion)
preview/        GIF previews of every animation + character-sheet.png
source/         Python scripts that generate all of the above (edit and re-run instead of hand-editing)
fonts/          Unbounded + Onest (OFL licensed)
```

## Using the animations in the iOS app
Add **lottie-ios** with Swift Package Manager: `https://github.com/airbnb/lottie-spm` (4.x). Put the `.json` files in the app bundle.

```swift
import Lottie
import SwiftUI

struct ShotsyAnimation: View {
    let name: String            // "shotsy-idle", "shotsy-whoa", …
    var loop = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LottieView(animation: .named(name))
            .playbackMode(reduceMotion
                ? .paused(at: .progress(1))                       // show the final pose, no motion
                : .playing(.fromProgress(0, toProgress: 1, loopMode: loop ? .loop : .playOnce)))
            .resizable()
            .accessibilityHidden(true)
    }
}
```
Where each one goes:
- Onboarding: `shotsy-hello-badge` on appear, then `shotsy-whoa-badge` right after photo access shows the count.
- Home header and empty states: `shotsy-idle` looping, small.
- Clean screen: `shotsy-tidy` when the last card is done and after "Delete N screenshots" succeeds, plus a success haptic.
- Recap: `shotsy-wink-badge` when the card appears.
Play each moment once per visit. Only one animated Shotsy on screen at a time.

Recolor at runtime (e.g. white corners on a dark card): every corner stroke is named `BracketStroke`, the badge fill `BadgeFill`.
```swift
.valueProvider(ColorValueProvider(UIColor.white.lottieColorValue),
               for: AnimationKeypath(keypath: "**.BracketStroke.Color"))
```
Other named parts (for keypaths): `Body`, `Eyes`, `EyeLeft`, `EyeRight`, `Smile`, `BigSmile`, `MouthO`, `HappyEyes`, `WinkEye`, `Blush`, `Sparkle`,
`BracketTopLeft/TopRight/BottomRight/BottomLeft`.

Small inline uses (the "o" in the wordmark, tab headers) stay as the SwiftUI `Canvas` mascot from CLAUDE.md — no Lottie needed.

## Lottie vs Rive vs SVG
- **Lottie (now):** best fit for these one-shot moments. Tiny files, plays natively, easy to swap.
- **Rive (later, optional):** worth it only if Shotsy becomes interactive — eyes following your finger in the swipe screen, reacting
  to each swipe. Rive files have to be made in the Rive editor: import the SVGs, 512×512 artboard, one state machine with a number
  input `mood` (0 hi, 1 whoa, 2 tidy, 3 wink), a trigger `blink`, a trigger `swipeLeft`/`swipeRight`, and a pointer listener that
  moves `Eyes` a few units toward the touch. Use the timings below.
- **Animated SVG:** web only (landing page, App Store promo site). iOS can't play SVG animation natively.

## Motion rules (for any new animation)
- Springy, not floaty: overshoot ~10%, settle in 150–250 ms. Ease in-out (sigmoid) everywhere.
- Blink: 5 frames close, 6 frames open at 60 fps. Never blink during another action.
- Squash and stretch max ±10%. Tilt max 7°.
- Corners are Shotsy's "arms": they spread out when surprised (+4–6 units), pull in when proud.
- Respect Reduce Motion: show the final pose, no movement.
