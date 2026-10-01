import SwiftData
import SwiftUI
import UserNotifications

@main
struct ShotsyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        Brand.registerFonts()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.settings)
                .environment(model.library)
                .environment(model.reviews)
                .environment(model.purchases)
                .environment(model.router)
                .environment(model.albums)
                .environment(model.analysis)
                .environment(model.screenshots)
                .environment(model.people)
                .environment(model.collections)
                .environment(model.compression)
                .modelContainer(model.container)
                .tint(Color.appAccent)
                .onOpenURL { model.handle($0) }
                .task {
                    AppDelegate.openURL = { [model] url in model.handle(url) }
                    if let pending = AppDelegate.pendingURL {
                        AppDelegate.pendingURL = nil
                        model.handle(pending)
                    }
                    if model.settings.hasOnboarded { model.start() }
                    #if DEBUG
                    // App Store captures: `-screenshotRoute library|albums|review|quick20|similar` opens a screen directly.
                    if UserDefaults.standard.string(forKey: "screenshotRoute") == "similar" {
                        try? await Task.sleep(for: .seconds(1))
                        model.router.tab = .clean
                        model.router.cleanPath.append(CleanRoute.similar)
                    } else if let route = UserDefaults.standard.string(forKey: "screenshotRoute"),
                       let url = URL(string: "\(DeepLink.scheme)://\(route)") {
                        try? await Task.sleep(for: .seconds(1))
                        model.handle(url)
                    }
                    #endif
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if settings.hasOnboarded {
                MainTabView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: settings.hasOnboarded)
        .onAppear { AppearanceController.apply(settings.appearance) }
        .onChange(of: settings.appearance) { _, new in AppearanceController.apply(new) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.sceneBecameActive() }
        }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Clean", systemImage: "sparkles", value: AppTab.clean) {
                CleanTab()
            }
            Tab("Library", systemImage: "photo.on.rectangle.angled", value: AppTab.library) {
                LibraryTab()
            }
            Tab("Albums", systemImage: "rectangle.stack", value: AppTab.albums) {
                AlbumsTab()
            }
        }
        .sheet(item: $router.sheet) { sheet in
            switch sheet {
            case .settings: SettingsView()
            case .paywall(let reason): PaywallView(reason: reason)
            case .reviewDeletions: NavigationStack { ReviewDeletionsView() }
            }
        }
        .fullScreenCover(item: $router.session) { route in
            SortSessionView(sessionID: route.id)
        }
    }
}

/// Applies the theme to every window, so open sheets switch instantly and "System" really follows the system.
/// (`.preferredColorScheme` doesn't update already-presented sheets and doesn't revert from a forced style.)
enum AppearanceController {
    static func apply(_ appearance: AppearanceSetting) {
        let style: UIUserInterfaceStyle = switch appearance {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                UIView.transition(with: window, duration: 0.25, options: .transitionCrossDissolve) {
                    window.overrideUserInterfaceStyle = style
                }
            }
        }
    }
}

enum AppSettings {
    static func open() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Routes reminder taps to the validated deep-link handler.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var openURL: ((URL) -> Void)?
    static var pendingURL: URL?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Completion-handler forms on purpose: the `async` forms finish off the main thread, and UIKit
    // crashes when a notification tap completes there.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let string = response.notification.request.content.userInfo["deepLink"] as? String
        nonisolated(unsafe) let done = completionHandler
        DispatchQueue.main.async {
            defer { done() }
            guard let string, let url = URL(string: string), DeepLink(url: url) != nil else { return }
            if let open = AppDelegate.openURL { open(url) } else { AppDelegate.pendingURL = url }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
