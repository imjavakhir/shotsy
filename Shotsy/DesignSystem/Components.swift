import SwiftUI

// MARK: - Soft app bar

extension View {
    /// The required soft, gradual app-bar edge: content scrolls beneath the navigation bar and fades
    /// through the native iOS 26 soft scroll-edge effect instead of a solid header with a hard line.
    /// Apply to every main scroll container (ScrollView, List, Form, grids).
    /// With Reduce Transparency on, the system itself switches to its more opaque presentation.
    func softAppBar() -> some View {
        self
            .scrollEdgeEffectStyle(.soft, for: .top)
            .toolbarBackgroundVisibility(.automatic, for: .navigationBar)
    }

    /// Paper/plum page background that extends under the bars (no separate header rectangle).
    /// Always fills the screen, so short content (empty states) sits centered on the page color
    /// instead of in a band floating on the sheet's default background.
    func pageBackground() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appBackground.ignoresSafeArea())
    }

    func card(padding: CGFloat = Space.m) -> some View {
        self
            .padding(padding)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Space.cardRadius, style: .continuous))
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = .appAccentFill

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appHeadline)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Space.l)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(tint.opacity(isEnabled ? 1 : 0.4), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appHeadline)
            .foregroundStyle(Color.appAccent)
            .padding(.horizontal, Space.l)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Color.appChip, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var destructivePrimary: PrimaryButtonStyle { PrimaryButtonStyle(tint: .appDanger) }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

// MARK: - Building blocks

struct SectionHeader: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.display(17, relativeTo: .headline))
                .foregroundStyle(Color.appText)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.appFootnote)
                    .foregroundStyle(Color.appSecondaryText)
            }
        }
    }
}

/// Mascot + short message for empty, permission, and completion states.
struct MascotMessage<Actions: View>: View {
    var mood: ShotsyMood = .hi
    var animated: ShotsyClip?
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: Space.s) {
            Group {
                if let animated {
                    ShotsyAnimation(clip: animated, loop: animated == .idle)
                } else {
                    ShotsyMascot(mood: mood)
                }
            }
            .frame(width: 112, height: 112)
            Text(title)
                .font(.display(22, relativeTo: .title2))
                .foregroundStyle(Color.appText)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.appCallout)
                .foregroundStyle(Color.appSecondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions()
                .padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xl)
        .padding(.horizontal, Space.l)
    }
}

extension MascotMessage where Actions == EmptyView {
    init(mood: ShotsyMood = .hi, animated: ShotsyClip? = nil, title: LocalizedStringKey, message: LocalizedStringKey) {
        self.init(mood: mood, animated: animated, title: title, message: message) { EmptyView() }
    }
}

/// Inline notice for partial results, offline media, and errors.
struct Notice: View {
    enum Kind { case info, warning, error }
    let kind: Kind
    let text: LocalizedStringKey
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(.appSubheadline)
                .foregroundStyle(Color.appText)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.appSubheadline.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(minHeight: Space.minTap)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.xs)
        .frame(minHeight: Space.minTap)
        .background(Color.appChip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch kind {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private var color: Color {
        switch kind {
        case .info: .appAccent
        case .warning: .orange
        case .error: .appDanger
        }
    }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(count, format: .number)
            .font(.appCaption)
            .monospacedDigit()
            .foregroundStyle(Color.appAccent)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 3)
            .background(Color.appChip, in: Capsule())
    }
}

/// Settings gear placed in every main tab's toolbar.
struct SettingsToolbarButton: ToolbarContent {
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: action) {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}
