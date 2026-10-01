import SwiftUI

enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// User preferences (UserDefaults). App metadata lives in SwiftData.
@Observable
final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: "onboarded") } }
    var appearance: AppearanceSetting { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: "haptics") } }
    /// Favorites are never suggested for deletion and are flagged in the review grid.
    var protectFavorites: Bool { didSet { defaults.set(protectFavorites, forKey: "protectFavorites") } }
    var ocrEnabled: Bool { didSet { defaults.set(ocrEnabled, forKey: "ocr") } }
    var categoryAnalysisEnabled: Bool { didSet { defaults.set(categoryAnalysisEnabled, forKey: "categoryAnalysis") } }
    var peopleEnabled: Bool { didSet { defaults.set(peopleEnabled, forKey: "people") } }
    var onThisDayEnabled: Bool { didSet { defaults.set(onThisDayEnabled, forKey: "onThisDay") } }
    /// Scan new and edited photos automatically. Off: scans run only from "Scan Now".
    var autoScanEnabled: Bool { didSet { defaults.set(autoScanEnabled, forKey: "autoScan") } }
    /// Hold automatic scans while Low Power Mode is on.
    var pauseOnLowPower: Bool { didSet { defaults.set(pauseOnLowPower, forKey: "pauseOnLowPower") } }
    var remindersEnabled: Bool { didSet { defaults.set(remindersEnabled, forKey: "reminders") } }
    /// Calendar weekdays, 1 = Sunday … 7 = Saturday.
    var reminderWeekdays: Set<Int> { didSet { defaults.set(Array(reminderWeekdays), forKey: "reminderWeekdays") } }
    var reminderHour: Int { didSet { defaults.set(reminderHour, forKey: "reminderHour") } }
    var reminderMinute: Int { didSet { defaults.set(reminderMinute, forKey: "reminderMinute") } }
    /// Set once the first real scan result has been celebrated with the Whoa mascot.
    var hasSeenFirstScan: Bool { didSet { defaults.set(hasSeenFirstScan, forKey: "seenFirstScan") } }
    var totalDeleted: Int { didSet { defaults.set(totalDeleted, forKey: "totalDeleted") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "haptics": true, "protectFavorites": true, "ocr": true, "categoryAnalysis": true,
            "onThisDay": true, "autoScan": true, "pauseOnLowPower": true, "reminderWeekdays": [1, 4], "reminderHour": 19, "reminderMinute": 0,
        ])
        hasOnboarded = defaults.bool(forKey: "onboarded")
        appearance = AppearanceSetting(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        hapticsEnabled = defaults.bool(forKey: "haptics")
        protectFavorites = defaults.bool(forKey: "protectFavorites")
        ocrEnabled = defaults.bool(forKey: "ocr")
        categoryAnalysisEnabled = defaults.bool(forKey: "categoryAnalysis")
        peopleEnabled = defaults.bool(forKey: "people")
        onThisDayEnabled = defaults.bool(forKey: "onThisDay")
        autoScanEnabled = defaults.bool(forKey: "autoScan")
        pauseOnLowPower = defaults.bool(forKey: "pauseOnLowPower")
        remindersEnabled = defaults.bool(forKey: "reminders")
        reminderWeekdays = Set((defaults.array(forKey: "reminderWeekdays") as? [Int]) ?? [1, 4])
        reminderHour = defaults.integer(forKey: "reminderHour")
        reminderMinute = defaults.integer(forKey: "reminderMinute")
        hasSeenFirstScan = defaults.bool(forKey: "seenFirstScan")
        totalDeleted = defaults.integer(forKey: "totalDeleted")
    }
}
