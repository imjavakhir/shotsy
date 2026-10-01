import Photos
import SwiftUI

enum CleanRoute: Hashable {
    case similar, duplicates, screenshots, blurry, largeVideos, onThisDay
    case bursts, screenRecordings, slowMotion, months
    case compress(String)
}

struct CleanTab: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var reviews
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(SettingsStore.self) private var settings
    @State private var months: [MonthProgress] = []
    @State private var monthSnapshot: MonthSnapshot?
    @State private var onThisDayCount = 0
    @State private var unfinished: UnfinishedSession?
    @State private var emptyQuick = false
    @State private var loadedChange: Int?

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.cleanPath) {
            ScrollView {
                VStack(spacing: Space.m) {
                    AccessBanner()
                    if library.access.canRead {
                        if library.isLoaded && library.allAssets.count == 0 {
                            MascotMessage(animated: .idle, title: "Nothing here yet",
                                          message: "Photos you take or save will show up here.")
                        } else {
                            SortCard(unfinished: unfinished, nextMonth: months.first.map { ($0.section, $0.ids) })
                            quickEntries
                            ReviewQueueRow()
                            MonthsSection(months: months)
                            FirstScanCard()
                            ScanStatusCard()
                            CategoryCards()
                        }
                    }
                }
                .padding(.horizontal, Space.page)
                .padding(.bottom, Space.xxl)
            }
            .softAppBar()
            .pageBackground()
            .navigationTitle("Clean")
            .toolbar { SettingsToolbarButton { router.sheet = .settings } }
            .navigationDestination(for: CleanRoute.self) { route in
                switch route {
                case .similar: SimilarPhotosView()
                case .duplicates: DuplicatesView()
                case .screenshots: ScreenshotInboxView()
                case .blurry: BlurryView()
                case .largeVideos: VideoCategoryView(kind: .large)
                case .screenRecordings: VideoCategoryView(kind: .screenRecordings)
                case .slowMotion: VideoCategoryView(kind: .slowMotion)
                case .bursts: BurstsView()
                case .months: AllMonthsView()
                case .onThisDay: OnThisDayView()
                case .compress(let id): CompressVideoView(assetID: id)
                }
            }
            .task(id: refreshKey) { await refresh() }
            .alert("Nothing left to sort", isPresented: $emptyQuick) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Every item Shotsy can see has been reviewed. Try a category below, or look through On This Day.")
            }
        }
    }

    /// Includes whether a sort session is open: the cover leaves this tab live, so its work pauses while
    /// sorting (every swipe bumps the review revision) and runs once when the session closes.
    private var refreshKey: String {
        "\(library.changeCount)-\(reviews.revision)-\(settings.onThisDayEnabled)-\(router.session == nil)"
    }

    private var quickEntries: some View {
        HStack(spacing: Space.s) {
            EntryTile(title: "Quick 20", icon: "bolt", detail: "A short sort") {
                if model.startQuick20() == nil, reviews.remainingToday != 0 { emptyQuick = true }
            }
            EntryTile(title: "Screenshot Inbox", icon: "tray", detail: "Sort and search") {
                router.cleanPath.append(CleanRoute.screenshots)
            }
            if settings.onThisDayEnabled && onThisDayCount > 0 {
                EntryTile(title: "On This Day", icon: "calendar", detail: "\(onThisDayCount) memories") {
                    router.cleanPath.append(CleanRoute.onThisDay)
                }
            }
        }
    }

    private func refresh() async {
        guard router.session == nil else { return }
        guard await BackgroundFetch.settle(changeCount: library.changeCount, loadedChangeCount: loadedChange) else { return }
        // A SwiftData fetch plus decoding session states: done here, not on every render of the card.
        let latest = reviews.latestUnfinished().map { record in
            let state = reviews.state(of: record)
            return UnfinishedSession(id: record.id, title: record.displayTitle,
                                     position: state.position, total: state.assetIDs.count)
        }
        if latest != unfinished { unfinished = latest }
        let change = library.changeCount
        let all = library.allAssets
        let decisions = reviews.ledger.decisions
        // Only decisions changed: reuse the library's months instead of walking PhotoKit again.
        let cached = loadedChange == change ? monthSnapshot : nil
        let countMemories = settings.onThisDayEnabled && library.access.canRead && all.count > 0
        let (snapshot, found, memories) = await BackgroundFetch.run {
            let snapshot = cached ?? MonthSnapshot.read(all)
            return (snapshot,
                    MonthPlanner.unsorted(snapshot.months, decisions: decisions),
                    countMemories ? OnThisDayLoader.count(decisions: decisions) : 0)
        }
        guard !Task.isCancelled else { return }
        monthSnapshot = snapshot
        months = found
        onThisDayCount = memories
        loadedChange = change
    }
}

// MARK: - Cards

/// The most recently touched unfinished session, read once per refresh.
private struct UnfinishedSession: Equatable {
    var id: UUID
    var title: String
    var position: Int
    var total: Int
}

private struct SortCard: View {
    let unfinished: UnfinishedSession?
    let nextMonth: (MonthSection, [String])?
    @Environment(AppModel.self) private var model
    @Environment(ReviewStore.self) private var reviews
    @Environment(PurchaseStore.self) private var purchases
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let unfinished {
                Text("Continue where you left off").font(.appSubheadline).foregroundStyle(Color.appSecondaryText)
                Text(unfinished.title).font(.display(24, relativeTo: .title2)).foregroundStyle(Color.appText)
                ProgressView(value: Double(unfinished.position), total: Double(max(1, unfinished.total)))
                    .tint(Color.appAccentFill)
                    .accessibilityLabel("Progress")
                    .accessibilityValue("\(unfinished.position) of \(unfinished.total)")
                Text("\(unfinished.position) of \(unfinished.total) sorted")
                    .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                Button("Continue sorting") { router.openSession(unfinished.id) }
                    .buttonStyle(.primary)
            } else if let (month, ids) = nextMonth {
                let unreviewed = ids.filter { reviews.decision(for: $0) == nil }.count
                Text("Next up").font(.appSubheadline).foregroundStyle(Color.appSecondaryText)
                Text(month.title).font(.display(24, relativeTo: .title2)).foregroundStyle(Color.appText)
                Text("\(unreviewed) of \(ids.count) not sorted yet")
                    .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                Button("Start sorting") { model.startMonth(month, assets: ids) }
                    .buttonStyle(.primary)
            } else {
                MascotMessage(animated: .idle, title: "All sorted",
                              message: "You've reviewed everything Shotsy can see. New photos will show up here.")
            }
            if let remaining = reviews.remainingToday, !purchases.isPro {
                HStack {
                    Text("\(remaining) free reviews left today")
                        .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                    Spacer()
                    Button("Go unlimited") { router.showPaywall(.dailyLimit) }
                        .font(.appFootnote.weight(.semibold))
                        .frame(minHeight: Space.minTap)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Space.l)
    }
}

private struct EntryTile: View {
    let title: LocalizedStringKey
    let icon: String
    let detail: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.appAccent)
                    .accessibilityHidden(true)
                Text(title).font(.appSubheadline.weight(.semibold)).foregroundStyle(Color.appText)
                    .lineLimit(2).minimumScaleFactor(0.8)
                Text(detail).font(.appCaption).foregroundStyle(Color.appSecondaryText).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .card(padding: Space.s)
        }
        .buttonStyle(.plain)
    }
}

private struct ReviewQueueRow: View {
    @Environment(ReviewStore.self) private var reviews
    @Environment(Router.self) private var router

    var body: some View {
        let count = reviews.pendingCount
        Button { router.sheet = .reviewDeletions } label: {
            HStack(spacing: Space.s) {
                Image(systemName: "trash")
                    .foregroundStyle(count > 0 ? Color.appDanger : Color.appSecondaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review deletions").font(.appHeadline).foregroundStyle(Color.appText)
                    Text(count == 0 ? "Nothing marked yet" : "\(count) marked · nothing deleted yet")
                        .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                }
                Spacer()
                if count > 0 { CountBadge(count: count) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.appSecondaryText)
            }
            .card()
        }
        .buttonStyle(.plain)
    }
}

/// Whoa, once, for the first real scan result.
private struct FirstScanCard: View {
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let s = analysis.summary
        let found = s.similar.count + s.duplicateCandidates.count + s.blurry.count
        if !settings.hasSeenFirstScan, analysis.phase == .complete, found > 0 {
            HStack(spacing: Space.m) {
                ShotsyAnimation(clip: .whoa).frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Whoa. First scan done.").font(.appHeadline).foregroundStyle(Color.appText)
                    Text("I found \(s.similar.count) groups of similar photos and \(s.blurry.count) that might be blurry. Take a look when you like.")
                        .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                }
                Button("Dismiss", systemImage: "xmark") { settings.hasSeenFirstScan = true }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: Space.minTap, minHeight: Space.minTap)
            }
            .card()
        }
    }
}

private struct ScanStatusCard: View {
    @Environment(AnalysisCoordinator.self) private var analysis

    /// Only visible while work is happening (or paused). When the scan is done there's nothing to say.
    var body: some View {
        if analysis.isRunning || analysis.phase == .paused {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack {
                    Text(title).font(.appSubheadline.weight(.semibold)).foregroundStyle(Color.appText)
                    Spacer()
                    Button(analysis.isRunning ? "Pause" : "Resume") {
                        analysis.isRunning ? analysis.pause() : analysis.resume()
                    }
                    .font(.appSubheadline.weight(.semibold))
                    .frame(minHeight: Space.minTap)
                }
                if analysis.isRunning, analysis.total > 0 {
                    ProgressView(value: Double(analysis.done), total: Double(analysis.total))
                        .tint(Color.appAccentFill)
                    Text("\(analysis.done) of \(analysis.total)")
                        .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                        .monospacedDigit()
                }
            }
            .card()
        }
    }

    private var title: LocalizedStringKey {
        switch analysis.phase {
        case .analyzingPhotos: "Looking through your photos"
        case .readingScreenshots: "Reading your screenshots"
        case .measuringVideos: "Checking your videos"
        default: "Scan paused"
        }
    }
}

private struct CategoryCards: View {
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(ReviewStore.self) private var reviews
    @Environment(SettingsStore.self) private var settings
    @Environment(Router.self) private var router
    @Environment(PhotoLibrary.self) private var library
    @State private var estimate = StorageEstimate.Result()
    /// Preview thumbnails of every card, resolved in one background fetch.
    @State private var previews: [String: PHAsset] = [:]

    var body: some View {
        let s = analysis.summary
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title: "Cleanup", detail: s.isPartial && analysis.isRunning ? "Scan in progress · partial results" : nil)
            StorageHeader(estimate: estimate)
            CategoryCard(title: "Similar Photos", icon: "square.on.square",
                         countText: "\(s.similar.count) groups", previews: assets(s.similar.prefix(4).map(\.suggestedKeeper))) {
                router.cleanPath.append(CleanRoute.similar)
            }
            CategoryCard(title: "Verified Duplicates", icon: "doc.on.doc",
                         countText: duplicateText(s), previews: assets(s.duplicateCandidates.prefix(4).compactMap(\.ids.first))) {
                router.cleanPath.append(CleanRoute.duplicates)
            }
            if !s.bursts.isEmpty {
                CategoryCard(title: "Bursts", icon: "square.stack.3d.down.right",
                             countText: "\(s.bursts.count) bursts", previews: assets(s.bursts.prefix(4).map(\.keeper))) {
                    router.cleanPath.append(CleanRoute.bursts)
                }
            }
            CategoryCard(title: "Screenshots", icon: "camera.viewfinder",
                         countText: "\(s.screenshotIDs.count) screenshots", previews: assets(Array(s.screenshotIDs.prefix(4)))) {
                router.cleanPath.append(CleanRoute.screenshots)
            }
            CategoryCard(title: "Blurry Candidates", icon: "camera.metering.unknown",
                         countText: "\(s.blurry.count) suggestions", previews: assets(Array(s.blurry.prefix(4)))) {
                router.cleanPath.append(CleanRoute.blurry)
            }
            CategoryCard(title: "Large Videos", icon: "video",
                         countText: videoText(s.largeVideos), previews: assets(s.largeVideos.prefix(4).map(\.id))) {
                router.cleanPath.append(CleanRoute.largeVideos)
            }
            if !s.screenRecordings.isEmpty {
                CategoryCard(title: "Screen Recordings", icon: "record.circle",
                             countText: videoText(s.screenRecordings), previews: assets(s.screenRecordings.prefix(4).map(\.id))) {
                    router.cleanPath.append(CleanRoute.screenRecordings)
                }
            }
            if !s.slowMotion.isEmpty {
                CategoryCard(title: "Slo-mo Videos", icon: "slowmo",
                             countText: videoText(s.slowMotion), previews: assets(s.slowMotion.prefix(4).map(\.id))) {
                    router.cleanPath.append(CleanRoute.slowMotion)
                }
            }
        }
        // Paused while a sort session is open (every swipe bumps the review revision); runs once when it closes.
        .task(id: "\(analysis.summaryRevision)-\(reviews.revision)-\(settings.protectFavorites)-\(router.session == nil)") {
            await updateEstimate()
        }
        .task(id: "\(analysis.summaryRevision)-\(library.changeCount)-\(router.session == nil)") { await loadPreviews() }
    }

    private func assets(_ ids: some Sequence<String>) -> [PHAsset] {
        ids.compactMap { previews[$0] }
    }

    /// The first few items of each card, the same ones the cards show.
    private func previewIDs(_ s: CategorySummary) -> [String] {
        var ids: [String] = s.similar.prefix(4).map(\.suggestedKeeper)
        ids += s.duplicateCandidates.prefix(4).compactMap(\.ids.first)
        ids += s.bursts.prefix(4).map(\.keeper)
        ids += s.screenshotIDs.prefix(4)
        ids += s.blurry.prefix(4)
        for videos in [s.largeVideos, s.screenRecordings, s.slowMotion] { ids += videos.prefix(4).map(\.id) }
        return ids
    }

    private func loadPreviews() async {
        guard router.session == nil else { return }
        let ids = previewIDs(analysis.summary)
        let canRead = library.access.canRead
        let map = await BackgroundFetch.run { canRead ? BackgroundFetch.assets(for: ids) : [:] }
        guard !Task.isCancelled else { return }
        previews = map
    }

    private func duplicateText(_ s: CategorySummary) -> LocalizedStringKey {
        let verified = analysis.verifiedDuplicates.count
        return verified > 0 ? "\(verified) verified groups" : "\(s.duplicateCandidates.count) to verify"
    }

    private func videoText(_ videos: [VideoItem]) -> LocalizedStringKey {
        let unknown = videos.filter { $0.bytes == nil }.count
        return unknown > 0 ? "\(videos.count) videos · \(unknown) sizes unknown" : "\(videos.count) videos"
    }

    private func updateEstimate() async {
        guard router.session == nil else { return }
        let s = analysis.summary
        let pixels = s.candidatePixels, large = s.largeVideos, others = s.screenRecordings + s.slowMotion
        let favorites = s.favoriteIDs
        let decisions = reviews.ledger.decisions
        let protect = settings.protectFavorites
        let result = await BackgroundFetch.run {
            let marked = Set(decisions.lazy.filter { $0.value == .marked }.map(\.key))
            return StorageEstimate.compute(photoPixels: pixels, largeVideos: large, otherVideos: others,
                                           excluded: marked, favorites: favorites, protectFavorites: protect)
        }
        guard !Task.isCancelled else { return }
        estimate = result
    }
}

/// "Free up about X": measured video bytes plus an estimate for photos, always labeled as such.
private struct StorageHeader: View {
    let estimate: StorageEstimate.Result

    var body: some View {
        if estimate.total > 0 {
            HStack(alignment: .top, spacing: Space.s) {
                Image(systemName: "internaldrive")
                    .font(.title3)
                    .foregroundStyle(Color.appAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Free up about \(ByteCountFormatter.string(fromByteCount: estimate.total, countStyle: .file))")
                        .font(.appHeadline).foregroundStyle(Color.appText)
                    Text(footnote).font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                    if estimate.unmeasuredVideos > 0 {
                        Text("Videos only in iCloud aren't counted.")
                            .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .card()
        }
    }

    private var footnote: LocalizedStringKey {
        switch (estimate.measuredVideoBytes > 0, estimate.estimatedPhotoBytes > 0) {
        case (true, true): "Video sizes are measured; photo sizes are estimated."
        case (true, false): "Video sizes are measured."
        default: "Photo sizes are estimated."
        }
    }
}

private struct CategoryCard: View {
    let title: LocalizedStringKey
    let icon: String
    let countText: LocalizedStringKey
    let previews: [PHAsset]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Label(title, systemImage: icon)
                        .font(.appHeadline)
                        .foregroundStyle(Color.appText)
                    Text(countText).font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                }
                Spacer(minLength: Space.xs)
                if !previews.isEmpty {
                    FannedStack(assets: previews, cardSize: CGSize(width: 40, height: 52), spread: 16, cornerRadius: 7)
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.appSecondaryText)
            }
            .frame(minHeight: 64)
            .card()
        }
        .buttonStyle(.plain)
    }
}

/// Permission states: not asked, denied, restricted, limited.
struct AccessBanner: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(AppModel.self) private var model

    var body: some View {
        switch library.access {
        case .full:
            EmptyView()
        case .limited:
            Notice(kind: .info, text: "Shotsy can see only the photos you selected. Counts cover those photos.",
                   actionTitle: "Manage", action: { LimitedLibrary.presentPicker() })
        case .notDetermined:
            MascotMessage(mood: .hi, title: "Connect your photos",
                          message: "Shotsy needs photo access to sort, group, and search. Everything is analyzed on this iPhone.") {
                Button("Continue") {
                    Task {
                        await library.requestAccess()
                        model.start()
                    }
                }
                .buttonStyle(.primary)
            }
            .card()
        case .denied:
            MascotMessage(mood: .hi, title: "Photo access is off",
                          message: "Turn on access in Settings to sort your library. Settings, restore purchases, and legal links still work.") {
                Button("Open Settings") { AppSettings.open() }.buttonStyle(.primary)
            }
            .card()
        case .restricted:
            MascotMessage(mood: .hi, title: "Photo access is restricted",
                          message: "This iPhone doesn't allow photo access, for example because of Screen Time or a device profile.")
                .card()
        }
    }
}
