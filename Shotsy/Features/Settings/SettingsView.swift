import StoreKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settings
    @Environment(PhotoLibrary.self) private var library
    @Environment(PurchaseStore.self) private var purchases
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var restoring = false
    @State private var restoreMessage: String?
    @State private var manageSubscriptions = false
    @State private var confirm: Confirm?
    @State private var reminderDenied = false

    enum Confirm: Identifiable {
        case clearCache, resetHistory
        var id: Self { self }
    }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Group {
                proSection

                Section("Appearance") {
                    Picker("Theme", selection: $settings.appearance) {
                        ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0) }
                    }
                    // iOS per-app language (Settings → Shotsy → Language). Unsupported languages fall back to English.
                    Button { AppSettings.open() } label: {
                        LabeledContent("Language") {
                            HStack(spacing: 4) {
                                Text(Self.currentLanguageName)
                                Image(systemName: "arrow.up.forward.app").font(.footnote)
                            }
                        }
                    }
                    .foregroundStyle(Color.appText)
                    Toggle("Haptics", isOn: $settings.hapticsEnabled)
                }

                Section {
                    LabeledContent("Access", value: accessText)
                    if library.access == .limited {
                        Button("Change selected photos") { LimitedLibrary.presentPicker() }
                    }
                    Button("Open Photos access in Settings") { AppSettings.open() }
                    Toggle("Protect favorites", isOn: $settings.protectFavorites)
                } header: {
                    Text("Photos")
                } footer: {
                    Text("Protected favorites are never suggested for deletion and start unselected in the review.")
                }

                Section {
                    Toggle("Find similar and blurry photos", isOn: $settings.categoryAnalysisEnabled)
                        .onChange(of: settings.categoryAnalysisEnabled) { _, on in on ? analysis.restart() : analysis.cancel() }
                    Toggle("Read screenshot text", isOn: $settings.ocrEnabled)
                        .onChange(of: settings.ocrEnabled) { analysis.restart() }
                    Toggle("On This Day", isOn: $settings.onThisDayEnabled)
                } header: {
                    Text("Analysis")
                } footer: {
                    Text("All analysis runs on this iPhone. Screenshot text search and suggestions are part of Shotsy Pro. Supported text languages: \((analysis.supportedOCRLanguages.isEmpty ? ImageAnalyzer.supportedOCRLanguages() : analysis.supportedOCRLanguages).prefix(10).joined(separator: ", ")).")
                }

                Section {
                    Toggle("Scan automatically", isOn: $settings.autoScanEnabled)
                        .onChange(of: settings.autoScanEnabled) { _, on in if on { analysis.startIfNeeded() } }
                    Toggle("Pause in Low Power Mode", isOn: $settings.pauseOnLowPower)
                        .onChange(of: settings.pauseOnLowPower) { _, on in if !on { analysis.startIfNeeded() } }
                    if analysis.isRunning {
                        Button("Pause scanning") { analysis.pause() }
                    } else {
                        Button("Scan Now") { analysis.scanNow() }
                            .disabled(!settings.categoryAnalysisEnabled)
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    if analysis.heldForLowPower {
                        Text("Scanning is waiting for Low Power Mode to end. Tap Scan Now to scan anyway.")
                    } else {
                        Text("Shotsy checks new and edited photos when your library changes. Turn off automatic scanning to scan only when you tap Scan Now.")
                    }
                }

                Section {
                    Toggle("Reminders", isOn: Binding(get: { settings.remindersEnabled }, set: { on in
                        Task {
                            if on {
                                if !(await model.reminders.enable()) { reminderDenied = true }
                            } else {
                                model.reminders.disable()
                            }
                        }
                    }))
                    if settings.remindersEnabled {
                        WeekdayPicker(selection: $settings.reminderWeekdays)
                            .onChange(of: settings.reminderWeekdays) { model.reminders.reconcile() }
                        DatePicker("Time", selection: reminderTime, displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    Text("A gentle local notification: “Ready for a quick photo sort?” Delivery depends on your notification settings.")
                }


                Section {
                    Button("Clear analysis cache") { confirm = .clearCache }
                    Button("Reset review history", role: .destructive) { confirm = .resetHistory }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("These only clear Shotsy's own data. They never delete anything from Photos.")
                }

                Section("About") {
                    NavigationLink("Privacy summary") { PrivacySummaryView() }
                    if let privacy = OwnerConfig.privacyPolicyURL { Link("Privacy Policy", destination: privacy) }
                    Link("Terms of Use (EULA)", destination: OwnerConfig.effectiveTermsURL)
                    if let email = OwnerConfig.supportEmail, let url = URL(string: "mailto:\(email)") {
                        Link("Contact support", destination: url)
                    }
                    LabeledContent("Version", value: Self.version)
                }
                }
                .listRowBackground(Color.appSurface)
            }
            .scrollContentBackground(.hidden)
            .softAppBar()
            .pageBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .manageSubscriptionsSheet(isPresented: $manageSubscriptions)
            .alert("Notifications are off", isPresented: $reminderDenied) {
                Button("Open Settings") { AppSettings.open() }
                Button("OK", role: .cancel) {}
            } message: {
                Text("Allow notifications for Shotsy in Settings to get reminders.")
            }
            .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible, presenting: confirm) { item in
                switch item {
                case .clearCache:
                    Button("Clear cache", role: .destructive) { Task { await analysis.clearCache() } }
                case .resetHistory:
                    Button("Reset history", role: .destructive) { model.reviews.resetHistory() }
                }
            } message: { item in
                switch item {
                case .clearCache: Text("Similar-photo, blur, and screenshot-text results will be rebuilt. Your labels and corrections stay.")
                case .resetHistory: Text("Forgets keep/mark decisions and sessions, including the deletion queue. Your photos aren't touched.")
                }
            }
        }
    }

    private var confirmTitle: String {
        switch confirm {
        case .clearCache: String(localized: "Clear analysis cache?")
        case .resetHistory: String(localized: "Reset review history?")
        case nil: ""
        }
    }

    @ViewBuilder private var proSection: some View {
        Section {
            switch purchases.entitlement {
            case .lifetime(let alsoWeekly):
                Label("Shotsy Pro · Lifetime", systemImage: "checkmark.seal.fill").foregroundStyle(Color.appSuccess)
                if alsoWeekly {
                    Text("You also have an active weekly subscription. Buying Lifetime doesn't cancel it; manage it below.")
                        .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                    Button("Manage subscription") { manageSubscriptions = true }
                }
            case .weekly(let expires):
                Label("Shotsy Pro · Weekly", systemImage: "checkmark.seal.fill").foregroundStyle(Color.appSuccess)
                if purchases.billingIssue {
                    Text("There's a billing issue. Access continues during Apple's grace period.")
                        .font(.appFootnote).foregroundStyle(.orange)
                } else if let expires {
                    Text(purchases.weeklyWillRenew ? "Renews \(expires.formatted(date: .abbreviated, time: .omitted))"
                                                   : "Ends \(expires.formatted(date: .abbreviated, time: .omitted))")
                        .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                }
                Button("Manage subscription") { manageSubscriptions = true }
            case .none:
                Button("Get Shotsy Pro") { dismiss(); router.showPaywall(.settings) }
            }
            Button {
                Task {
                    restoring = true
                    let result = await purchases.restore()
                    restoring = false
                    switch result {
                    case .success: restoreMessage = String(localized: "Purchases restored.")
                    case .failed(let m): restoreMessage = m
                    case .cancelled, .pending: restoreMessage = nil
                    }
                }
            } label: {
                if restoring { ProgressView() } else { Text("Restore Purchases") }
            }
            if let restoreMessage { Text(restoreMessage).font(.appFootnote).foregroundStyle(Color.appSecondaryText) }
        } header: {
            Text("Shotsy Pro")
        }
    }

    private var accessText: String {
        switch library.access {
        case .full: String(localized: "All photos")
        case .limited: String(localized: "Selected photos")
        case .denied: String(localized: "Off")
        case .restricted: String(localized: "Restricted")
        case .notDetermined: String(localized: "Not asked yet")
        }
    }

    private var reminderTime: Binding<Date> {
        Binding(get: {
            Calendar.current.date(from: DateComponents(hour: settings.reminderHour, minute: settings.reminderMinute)) ?? .now
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            settings.reminderHour = c.hour ?? 19
            settings.reminderMinute = c.minute ?? 0
            model.reminders.reconcile()
        })
    }

    /// The language the app is actually running in, in that language (e.g. "Русский").
    static var currentLanguageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}

private struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let first = Calendar.current.firstWeekday
        let order = (0..<7).map { (first - 1 + $0) % 7 + 1 }
        HStack {
            ForEach(order, id: \.self) { day in
                let on = selection.contains(day)
                Button {
                    if on { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(symbols[day - 1])
                        .font(.appSubheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(on ? Color.appAccentFill : Color.appChip, in: Circle())
                        .foregroundStyle(on ? .white : Color.appText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct PrivacySummaryView: View {
    var body: some View {
        List {
            Section {
                Label("Photos are analyzed on this iPhone: similar photos, blur, and screenshot text.", systemImage: "iphone")
                Label("Shotsy doesn't send your photos, text, or identifiers to any server. There are no analytics SDKs.", systemImage: "lock")
                Label("Your library changes only when you choose an action. Deletions always go through Apple's confirmation.", systemImage: "hand.raised")
                Label("Analysis results are excluded from backups and can be cleared in Settings.", systemImage: "externaldrive.badge.xmark")
                Label("Network use: Apple Photos may download iCloud originals when you open, share, verify, or compress them. Purchases go through the App Store and RevenueCat.", systemImage: "icloud")
            }
            .font(.appCallout)
        }
        .softAppBar()
        .navigationTitle("Privacy")
    }
}
