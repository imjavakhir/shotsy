import SwiftUI
import UIKit

/// Fixed brand colors from the Shotsy kit (MASCOT.md). Mascot face colors never change with appearance.
enum Brand {
    static let grape = Color(hex: 0x5B3FD9)
    static let lilac = Color(hex: 0xA794FF)
    static let ink = Color(hex: 0x1B1633)
    static let paper = Color(hex: 0xF5F3FC)
    static let blush = Color(hex: 0xFFA8CF)
    static let mint = Color(hex: 0x43D9A3)

    /// Registers the bundled static font instances. Call once at launch.
    static func registerFonts() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Unbounded for large navigation titles only; inline titles stay system for native controls.
    static func configureNavigationBarFonts() {
        guard let unbounded = UIFont(name: "Unbounded-ExtraBold", size: 30) else { return }
        let large = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: unbounded)
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: large]
    }
}

/// Semantic tokens. Light values come from the brand; dark values are plum surfaces
/// chosen for contrast (text ≥ 7:1, secondary ≥ 4.5:1 on both surfaces).
extension Color {
    static let appBackground = Color(light: 0xF5F3FC, dark: 0x141120)
    static let appSurface = Color(light: 0xFFFFFF, dark: 0x211B34)
    static let appSurfaceRaised = Color(light: 0xFFFFFF, dark: 0x2A2340)
    static let appText = Color(light: 0x1B1633, dark: 0xF3F0FF)
    static let appSecondaryText = Color(light: 0x5E5877, dark: 0xB7AFD6)
    static let appLine = Color(light: 0xE6E1F7, dark: 0x352D50)
    /// Accent for text, icons and tints. Grape in light mode; a lighter lilac in dark for contrast.
    static let appAccent = Color(light: 0x5B3FD9, dark: 0xB6A7FF)
    /// Filled buttons. Grape in both modes; always paired with white text (never white on lilac).
    static let appAccentFill = Color(light: 0x5B3FD9, dark: 0x6A50E6)
    static let appDanger = Color(light: 0xC62F52, dark: 0xFF8AA0)
    static let appSuccess = Color(light: 0x14865E, dark: 0x43D9A3)
    static let appChip = Color(light: 0xECE8FA, dark: 0x2E2745)

    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Font {
    /// Unbounded ExtraBold for short display headings and big numbers. Scales with Dynamic Type.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("Unbounded-ExtraBold", size: size, relativeTo: style)
    }

    /// Onest for interface text. Scales with Dynamic Type.
    static func onest(_ size: CGFloat, _ weight: OnestWeight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(weight.postScriptName, size: size, relativeTo: style)
    }

    enum OnestWeight {
        case regular, medium, semibold, bold

        var postScriptName: String {
            switch self {
            case .regular: "Onest-Regular"
            case .medium: "Onest-Medium"
            case .semibold: "Onest-SemiBold"
            case .bold: "Onest-Bold"
            }
        }
    }

    // Standard roles.
    static let appBody = Font.onest(17, relativeTo: .body)
    static let appCallout = Font.onest(16, relativeTo: .callout)
    static let appSubheadline = Font.onest(15, relativeTo: .subheadline)
    static let appFootnote = Font.onest(13, relativeTo: .footnote)
    static let appCaption = Font.onest(12, .medium, relativeTo: .caption)
    static let appHeadline = Font.onest(17, .semibold, relativeTo: .headline)
    static let appTitle = Font.display(22, relativeTo: .title2)
}

/// 4/8 pt spacing scale.
enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    /// Default horizontal page margin.
    static let page: CGFloat = 20
    static let cardRadius: CGFloat = 22
    static let minTap: CGFloat = 44
}
