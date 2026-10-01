import SwiftUI

enum ShotsyMood: CaseIterable {
    case hi, whoa, tidy, wink
}

/// Static Shotsy drawn with Canvas, geometry copied 1:1 from brand/source/build_svg.py (100×100 space).
/// Use for small inline spots (headers, rows, share cards). Use `ShotsyAnimation` for the animated moments.
struct ShotsyMascot: View {
    enum Style {
        /// Grape corners, for light backgrounds.
        case light
        /// White corners on a lilac rounded square (the app icon look).
        case badge
        /// Custom corner color, e.g. white on a dark card.
        case corners(Color)
    }

    var mood: ShotsyMood = .hi
    var style: Style = .light
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { ctx, size in
            let side = min(size.width, size.height)
            let s = side / 100
            ctx.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            ctx.scaleBy(x: s, y: s)

            var faceSide = side
            let cornerColor: Color
            switch style {
            case .light where colorScheme == .dark:
                // Brand rule: on dark backgrounds use the badge variant.
                cornerColor = .white
                ctx.fill(
                    Path(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerRadius: 22.5, style: .continuous),
                    with: .color(Brand.lilac)
                )
                ctx.translateBy(x: 11, y: 11)
                ctx.scaleBy(x: 0.78, y: 0.78)
                faceSide *= 0.78
            case .light:
                cornerColor = Brand.grape
            case .corners(let c):
                cornerColor = c
            case .badge:
                cornerColor = .white
                ctx.fill(
                    Path(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerRadius: 22.5, style: .continuous),
                    with: .color(Brand.lilac)
                )
                ctx.translateBy(x: 11, y: 11)
                ctx.scaleBy(x: 0.78, y: 0.78)
                faceSide *= 0.78
            }
            // Brand rule: drop the blush below 44pt.
            Self.drawFace(mood, in: &ctx, corners: cornerColor, blush: faceSide >= 44)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Shotsy")
        .accessibilityHidden(true)
    }

    static func drawFace(_ mood: ShotsyMood, in ctx: inout GraphicsContext, corners: Color, blush showBlush: Bool) {
        let ink = GraphicsContext.Shading.color(Brand.ink)
        let line = StrokeStyle(lineWidth: 4.5, lineCap: .round)

        ctx.stroke(brackets(spread: mood == .whoa), with: .color(corners),
                   style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))

        if showBlush {
            let x: CGFloat = mood == .whoa ? 28 : 31
            ctx.fill(Path(ellipseIn: CGRect(x: x - 5, y: 55, width: 10, height: 6)), with: .color(Brand.blush))
            ctx.fill(Path(ellipseIn: CGRect(x: 100 - x - 5, y: 55, width: 10, height: 6)), with: .color(Brand.blush))
        }

        func eye(_ cx: CGFloat) {
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 5, y: 40.5, width: 10, height: 13)), with: ink)
            ctx.fill(Path(ellipseIn: CGRect(x: cx + 0.1, y: 42.9, width: 3.4, height: 3.4)), with: .color(.white))
        }
        func curve(_ from: CGPoint, _ control: CGPoint, _ to: CGPoint) -> Path {
            var p = Path()
            p.move(to: from)
            p.addQuadCurve(to: to, control: control)
            return p
        }
        let smile = curve(CGPoint(x: 43, y: 58), CGPoint(x: 50, y: 65), CGPoint(x: 57, y: 58))

        switch mood {
        case .hi:
            eye(40); eye(60)
            ctx.stroke(smile, with: ink, style: line)

        case .whoa:
            for cx: CGFloat in [39, 61] {
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 6.5, y: 37, width: 13, height: 16)), with: ink)
                ctx.fill(Path(ellipseIn: CGRect(x: cx + 0.2, y: 40, width: 4, height: 4)), with: .color(.white))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: 45.5, y: 58.5, width: 9, height: 11)), with: ink)

        case .tidy:
            ctx.stroke(curve(CGPoint(x: 34, y: 49), CGPoint(x: 40, y: 41), CGPoint(x: 46, y: 49)), with: ink, style: line)
            ctx.stroke(curve(CGPoint(x: 54, y: 49), CGPoint(x: 60, y: 41), CGPoint(x: 66, y: 49)), with: ink, style: line)
            ctx.stroke(curve(CGPoint(x: 41, y: 56), CGPoint(x: 50, y: 67), CGPoint(x: 59, y: 56)), with: ink, style: line)
            var sparkle = Path()
            sparkle.addLines([
                CGPoint(x: 90, y: 3), CGPoint(x: 92, y: 8), CGPoint(x: 97, y: 10), CGPoint(x: 92, y: 12),
                CGPoint(x: 90, y: 17), CGPoint(x: 88, y: 12), CGPoint(x: 83, y: 10), CGPoint(x: 88, y: 8),
            ])
            sparkle.closeSubpath()
            ctx.fill(sparkle, with: .color(Brand.mint))

        case .wink:
            eye(40)
            ctx.stroke(curve(CGPoint(x: 55, y: 47), CGPoint(x: 60, y: 51), CGPoint(x: 65, y: 47)), with: ink, style: line)
            ctx.stroke(smile, with: ink, style: line)
        }
    }

    /// The four crop-handle corners. Whoa spreads them out ("arms up").
    private static func brackets(spread: Bool) -> Path {
        let c: CGFloat = spread ? 16 : 20     // corner inset
        let e: CGFloat = spread ? 36 : 38     // where each arm ends
        let r: CGFloat = 8
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: c, y: e), CGPoint(x: c, y: c), CGPoint(x: e, y: c)),
            (CGPoint(x: 100 - e, y: c), CGPoint(x: 100 - c, y: c), CGPoint(x: 100 - c, y: e)),
            (CGPoint(x: 100 - c, y: 100 - e), CGPoint(x: 100 - c, y: 100 - c), CGPoint(x: 100 - e, y: 100 - c)),
            (CGPoint(x: e, y: 100 - c), CGPoint(x: c, y: 100 - c), CGPoint(x: c, y: 100 - e)),
        ]
        var p = Path()
        for (start, corner, end) in corners {
            p.move(to: start)
            p.addArc(tangent1End: corner, tangent2End: end, radius: r)
            p.addLine(to: end)
        }
        return p
    }
}

#Preview {
    VStack(spacing: 24) {
        HStack { ForEach(ShotsyMood.allCases, id: \.self) { ShotsyMascot(mood: $0).frame(width: 80) } }
        HStack { ForEach(ShotsyMood.allCases, id: \.self) { ShotsyMascot(mood: $0, style: .badge).frame(width: 80) } }
    }
    .padding()
    .background(Color.appBackground)
}
