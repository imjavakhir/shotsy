import Photos
import SwiftData
import SwiftUI

/// Owns and wires the app's services. Injected into the environment once.
@Observable
final class AppModel {
    let container: ModelContainer
    let settings: SettingsStore
    let library: PhotoLibrary
    let albums: AlbumService
    let deletion: DeletionService
    let reviews: ReviewStore
    let purchases: PurchaseStore
    let router: Router
    let analysis: AnalysisCoordinator
    let screenshots: ScreenshotStore
    let people: PeopleStore
    let collections: SmartCollectionStore
    let compression: CompressionStore
    let reminders: ReminderScheduler

    /// Non-nil if the database couldn't be opened; the app runs with an in-memory store and says so.
    private(set) var storageError: String?

    init() {
        let container: ModelContainer
        var storageError: String?
        do {
            container = try PersistenceController.makeContainer()
        } catch {
            storageError = error.localizedDescription
            container = try! PersistenceController.makeContainer(inMemory: true)
        }
        self.container = container
        self.storageError = storageError

        let context = container.mainContext
        settings = SettingsStore()
        library = PhotoLibrary()
        albums = AlbumService(library: library)
        deletion = DeletionService(library: library)
        reviews = ReviewStore(context: context)
        purchases = PurchaseStore()
        router = Router()
        analysis = AnalysisCoordinator(container: container, library: library, settings: settings)
        screenshots = ScreenshotStore(context: context)
        people = PeopleStore(container: container, library: library, settings: settings)
        collections = SmartCollectionStore(context: context)
        compression = CompressionStore(context: context, library: library)
        reminders = ReminderScheduler(settings: settings)

        reviews.isPro = { [purchases] in purchases.isPro }
        analysis.isPro = { [purchases] in purchases.isPro }
        people.isPro = { [purchases] in purchases.isPro }
        library.onAssetsRemoved = { [weak self] removed in self?.assetsRemoved(removed) }
        library.onChange = { [weak self] in self?.analysis.libraryChanged() }
        purchases.onEntitlementChange = { [weak self] entitlement, initial in
            // Upgrading unlocks OCR indexing; losing Pro only gates new premium processing.
            // At launch the scan already running reads isPro before its OCR pass, so don't restart it.
            guard entitlement.isPro, let self else { return }
            if initial { self.analysis.startIfNeeded() } else { self.analysis.restart() }
        }
    }

    @ObservationIgnored private var started = false

    /// Unit tests run inside the app; don't start background work there.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// DEBUG-only: `-screenshotMode YES` skips background scanning so App Store captures are clean
    /// (the simulator can't run Vision, so a scan would never finish there).
    static var isScreenshotMode: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "screenshotMode")
        #else
        false
        #endif
    }

    func start() {
        guard !started, !Self.isRunningTests else { return }
        started = true
        Brand.configureNavigationBarFonts()
        purchases.start()
        compression.cleanAbandonedFiles()
        reminders.reconcile()
        if library.access.canRead && !Self.isScreenshotMode {
            analysis.startIfNeeded()
            people.startIfEnabled()
        }
        // Captures show the results of an earlier scan without starting a new one.
        if library.access.canRead && Self.isScreenshotMode { Task { await analysis.summarize() } }
    }

    func sceneBecameActive() {
        library.refreshAccess()
        reminders.reconcile()
        Task { await purchases.refreshEntitlements() }
        // No scan here: library changes (including ones made while away) arrive through the change
        // observer, which schedules a debounced pass only when assets were added or edited.
    }

    // MARK: Reconciliation

    private func assetsRemoved(_ removed: Set<String>) {
        reviews.forget(removed)
        analysis.forget(removed)
        people.forget(removed)
    }

    // MARK: Sessions

    /// Starts a Quick 20 session: up to 20 unreviewed accessible assets, capped by the free allowance.
    /// Returns nil when nothing is eligible (the caller shows the empty state).
    @discardableResult
    func startQuick20() -> UUID? {
        let remaining = reviews.remainingToday
        if remaining == 0 {
            router.showPaywall(.dailyLimit)
            return nil
        }
        let ids = SessionBuilder.quick(from: library.allIdentifiers(), ledger: reviews.ledger,
                                       limit: Policy.current.quickSessionSize, remainingQuota: remaining)
        guard !ids.isEmpty else { return nil }
        let record = reviews.createSession(kind: .quick20, title: String(localized: "Quick 20"), assetIDs: ids)
        router.openSession(record.id)
        return record.id
    }

    /// Resumes the month's unfinished session or starts one with its unreviewed assets.
    @discardableResult
    func startMonth(_ month: MonthSection, assets: [String]) -> UUID? {
        if let existing = reviews.unfinishedMonthSession(monthKey: month.key) {
            router.openSession(existing.id)
            return existing.id
        }
        let ids = SessionBuilder.month(from: assets, ledger: reviews.ledger)
        guard !ids.isEmpty else { return nil }
        let record = reviews.createSession(kind: .month, title: month.title, assetIDs: ids, monthKey: month.key)
        router.openSession(record.id)
        return record.id
    }

    @discardableResult
    func startSession(kind: SessionKind, title: String, assetIDs: [String]) -> UUID? {
        let ids = SessionBuilder.month(from: assetIDs, ledger: reviews.ledger)
        guard !ids.isEmpty else { return nil }
        let record = reviews.createSession(kind: kind, title: title, assetIDs: ids)
        router.openSession(record.id)
        return record.id
    }

    // MARK: Deep links

    func handle(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        switch link {
        case .clean: router.tab = .clean
        case .library: router.tab = .library
        case .albums: router.tab = .albums
        case .reviewDeletions:
            router.tab = .clean
            router.sheet = .reviewDeletions
        case .quick20:
            router.tab = .clean
            if library.access.canRead { startQuick20() }
        case .session(let id):
            router.tab = .clean
            if let record = reviews.session(id: id), !reviews.state(of: record).isFinished {
                router.openSession(id)
            }
        }
    }
}
