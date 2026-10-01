import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settings
    @Environment(PhotoLibrary.self) private var library
    @State private var page = 0
    @State private var connecting = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                howItWorks.tag(1)
                connect.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: Space.xs) {
                if page < 2 {
                    Button("Continue") { withAnimation { page += 1 } }
                        .buttonStyle(.primary)
                } else {
                    Button {
                        Task {
                            connecting = true
                            await library.requestAccess()
                            connecting = false
                            settings.hasOnboarded = true
                            model.start()
                        }
                    } label: {
                        if connecting { ProgressView().tint(.white) } else { Text("Continue") }
                    }
                    .buttonStyle(.primary)
                    .disabled(connecting)
                    Button("Not now") { settings.hasOnboarded = true; model.start() }
                        .font(.appHeadline)
                        .frame(minHeight: Space.minTap)
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.s)
        }
        .pageBackground()
    }

    private var welcome: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                ShotsyAnimation(clip: .hello, badge: true)
                    .frame(width: 180, height: 180)
                    .padding(.top, Space.xxl)
                Text("Make room for the photos you love.")
                    .font(.display(30, relativeTo: .largeTitle))
                    .foregroundStyle(Color.appText)
                    .multilineTextAlignment(.center)
                Text("Hi, I'm Shotsy. I help you sort your camera roll a little at a time.")
                    .font(.appBody)
                    .foregroundStyle(Color.appSecondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Space.xl)
        }
    }

    private var howItWorks: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                Text("How it works")
                    .font(.display(26, relativeTo: .title))
                    .foregroundStyle(Color.appText)
                    .padding(.top, Space.xxl)
                feature("hand.draw", "Swipe to sort",
                        "Right to keep, left to mark for deletion, up to add to an album. Nothing is deleted until you review and confirm.")
                feature("rectangle.stack", "Albums that make sense",
                        "Add photos to albums, and save smart filters that update themselves.")
                feature("iphone", "Analysis stays on this iPhone",
                        "Similar photos, screenshot text, and faces are analyzed on device. Shotsy changes your library only when you choose an action.")
            }
            .padding(.horizontal, Space.xl)
        }
    }

    private var connect: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                ShotsyMascot(mood: .hi, style: .badge)
                    .frame(width: 120, height: 120)
                    .padding(.top, Space.xxl)
                Text("Connect your photos")
                    .font(.display(26, relativeTo: .title))
                    .foregroundStyle(Color.appText)
                    .multilineTextAlignment(.center)
                Text("You can give Shotsy access to all photos, or only the ones you pick. Photos stored in iCloud may download when you open or compress them.")
                    .font(.appBody)
                    .foregroundStyle(Color.appSecondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Space.xl)
        }
    }

    private func feature(_ icon: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.appAccent)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(.appHeadline).foregroundStyle(Color.appText)
                Text(text).font(.appCallout).foregroundStyle(Color.appSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

}
