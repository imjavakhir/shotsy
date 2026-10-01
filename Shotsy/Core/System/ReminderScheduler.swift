import Foundation
import UserNotifications

nonisolated enum ReminderPlan {
    static let identifierPrefix = "shotsy.reminder."

    /// One repeating calendar trigger per selected weekday (1 = Sunday … 7 = Saturday), in local time.
    /// Components carry no time zone, so they follow the device's current time zone automatically.
    static func requests(weekdays: Set<Int>, hour: Int, minute: Int) -> [(id: String, components: DateComponents)] {
        weekdays.filter { (1...7).contains($0) }.sorted().map { day in
            var c = DateComponents()
            c.weekday = day
            c.hour = max(0, min(23, hour))
            c.minute = max(0, min(59, minute))
            return (identifierPrefix + "\(day)", c)
        }
    }
}

/// Optional local reminders. Permission is requested only when the user turns them on.
/// Reconcile replaces Shotsy's pending reminders whenever they differ from the plan, so schedules never duplicate.
@Observable
final class ReminderScheduler {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private let settings: SettingsStore
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(settings: SettingsStore) {
        self.settings = settings
        observer = NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    /// Turning on asks for permission; returns false if the user declined.
    func enable() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        await refreshAuthorization()
        settings.remindersEnabled = granted
        reconcile()
        return granted
    }

    func disable() {
        settings.remindersEnabled = false
        reconcile()
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func reconcile() {
        let enabled = settings.remindersEnabled
        let plan = ReminderPlan.requests(weekdays: settings.reminderWeekdays, hour: settings.reminderHour,
                                         minute: settings.reminderMinute)
        Task {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            let ours = pending.filter { $0.identifier.hasPrefix(ReminderPlan.identifierPrefix) }
            await refreshAuthorization()
            let wanted = enabled && (authorization == .authorized || authorization == .provisional) ? plan : []
            // Runs on every foreground; leave the schedule alone when it already matches.
            if Self.matches(ours, wanted) { return }
            center.removePendingNotificationRequests(withIdentifiers: ours.map(\.identifier))
            for item in wanted {
                let trigger = UNCalendarNotificationTrigger(dateMatching: item.components, repeats: true)
                try? await center.add(UNNotificationRequest(identifier: item.id, content: Self.content(), trigger: trigger))
            }
        }
    }

    private static func content() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        // Neutral text: no counts that could be stale.
        content.title = String(localized: "Shotsy")
        content.body = String(localized: "Ready for a quick photo sort?")
        content.userInfo = ["deepLink": DeepLink.quick20.url.absoluteString]
        return content
    }

    /// True when the pending reminders are exactly the wanted ones (same days, time and text).
    private static func matches(_ pending: [UNNotificationRequest], _ wanted: [(id: String, components: DateComponents)]) -> Bool {
        guard pending.count == wanted.count else { return false }
        let expected = content()
        let byID = Dictionary(pending.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        return wanted.allSatisfy { item in
            guard let request = byID[item.id],
                  let trigger = request.trigger as? UNCalendarNotificationTrigger, trigger.repeats else { return false }
            let c = trigger.dateComponents
            return c.weekday == item.components.weekday && c.hour == item.components.hour
                && c.minute == item.components.minute
                && request.content.title == expected.title && request.content.body == expected.body
                && request.content.userInfo["deepLink"] as? String == DeepLink.quick20.url.absoluteString
        }
    }
}
