import Photos
import SwiftUI

// MARK: - Similar photos

struct SimilarPhotosView: View {
    @Environment(AnalysisCoordinator.self) private var analysis

    var body: some View {
        let groups = analysis.summary.similar
        List {
            if analysis.summary.isPartial {
                Notice(kind: .info, text: "Still scanning. More groups may appear.")
                    .listRowBackground(Color.clear)
            }
            if groups.isEmpty {
                MascotMessage(animated: .idle, title: "No similar photos",
                              message: analysis.summary.isPartial ? "Nothing yet. I'm still looking." : "Nothing to compare right now.")
                    .listRowBackground(Color.clear)
            }
            ForEach(groups) { group in
                GroupRow(group: group, verified: false)
                    .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.page, bottom: Space.xs, trailing: Space.page))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .softAppBar()
        .pageBackground()
        .navigationTitle("Similar Photos")
    }
}

/// One group, side by side, with the suggested keeper and an overridable selection.
struct GroupRow: View {
    let group: SimilarGroup
    let verified: Bool

    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var reviews
    @Environment(SettingsStore.self) private var settings
    @Environment(PurchaseStore.self) private var purchases
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var model
    @State private var keeper: String = ""
    @State private var selection = Set<String>()
    @State private var preview: PreviewRequest?
    @State private var message: String?
    /// Resolved once per group or library change, off the main actor (not on every render).
    @State private var assets: [PHAsset] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text(verified ? "\(group.ids.count) identical files" : "\(group.ids.count) similar photos")
                    .font(.appHeadline).foregroundStyle(Color.appText)
                Spacer()
                if let date = assets.first?.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Space.xs) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        let id = asset.localIdentifier
                        VStack(spacing: 4) {
                            AssetThumbnail(asset: asset, targetSide: 160)
                                .frame(width: 130, height: 170)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: selection.contains(id) ? "trash.circle.fill" : "circle")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, selection.contains(id) ? Color.appDanger : .black.opacity(0.3))
                                        .padding(4)
                                }
                                .overlay(alignment: .bottom) {
                                    if id == keeper {
                                        Text("Keep").font(.appCaption).foregroundStyle(.white)
                                            .padding(.horizontal, 8).padding(.vertical, 3)
                                            .background(Color.appSuccess, in: Capsule()).padding(4)
                                    }
                                }
                                .onTapGesture { toggle(id) }
                                .contextMenu {
                                    Button("Make this the keeper", systemImage: "star") { setKeeper(id) }
                                    Button("Preview", systemImage: "eye") { preview = PreviewRequest(ids: group.ids, start: id) }
                                }
                            Text("\(asset.pixelWidth)×\(asset.pixelHeight)").font(.appCaption).foregroundStyle(Color.appSecondaryText)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(AssetDescription.label(for: asset))
                        .accessibilityValue(selection.contains(id) ? String(localized: "Selected for deletion") : (id == keeper ? String(localized: "Keeper") : ""))
                        .accessibilityAction(named: "Toggle selection") { toggle(id) }
                        .accessibilityAction(named: "Make keeper") { setKeeper(id) }
                    }
                }
            }
            Label {
                Text(verified ? "Files match byte for byte. Suggested keeper: \(String(localized: group.reason.text))."
                              : "Suggested keeper: \(String(localized: group.reason.text)). Tap photos to change.")
            } icon: { Image(systemName: "lightbulb") }
                .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
            if let message { Text(message).font(.appFootnote).foregroundStyle(Color.appSecondaryText) }
            HStack {
                Button {
                    markSelected()
                } label: {
                    Label(purchases.isPro ? "Mark \(selection.count)" : "Mark \(selection.count) (Pro)",
                          systemImage: purchases.isPro ? "trash" : "lock")
                }
                .buttonStyle(.secondary)
                .disabled(selection.isEmpty)
                Button("Review one by one") {
                    model.startSession(kind: .category, title: String(localized: "Similar photos"), assetIDs: group.ids)
                }
                .buttonStyle(.secondary)
            }
        }
        .card()
        .task(id: GroupLoadKey(ids: group.ids, changeCount: library.changeCount)) {
            let ids = group.ids
            let canRead = library.access.canRead
            let map = await BackgroundFetch.run { canRead ? BackgroundFetch.assets(for: ids) : [:] }
            guard !Task.isCancelled else { return }
            assets = ids.compactMap { map[$0] }
            // First load: suggest a selection once favorites are known.
            guard keeper.isEmpty else { return }
            keeper = group.suggestedKeeper
            selection = SimilarityGrouper.defaultSelection(for: group, favorites: Set(assets.filter(library.isFavorite).map(\.localIdentifier)),
                                                           protectFavorites: settings.protectFavorites)
                .filter { reviews.decision(for: $0) != .marked }
        }
        .fullScreenCover(item: $preview) { AssetPreviewView(request: $0) }
    }

    nonisolated private struct GroupLoadKey: Equatable {
        var ids: [String]
        var changeCount: Int
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            // Always keep at least one: never select every member.
            guard selection.count + 1 < group.ids.count else {
                message = String(localized: "Keep at least one photo from each group.")
                return
            }
            selection.insert(id)
            if id == keeper, let other = group.ids.first(where: { !selection.contains($0) }) { keeper = other }
        }
    }

    private func setKeeper(_ id: String) {
        keeper = id
        selection.remove(id)
    }

    private func markSelected() {
        guard purchases.isPro else { router.showPaywall(.batchCleanup); return }
        let ids = Array(selection.subtracting([keeper]))
        do {
            try reviews.decide(.marked, ids: ids)
            try? reviews.decide(.keep, ids: [keeper])
            message = String(localized: "Marked \(ids.count). Review them in Review deletions.")
            selection.removeAll()
        } catch {
            router.showPaywall(.dailyLimit)
        }
    }
}

// MARK: - Verified duplicates

struct DuplicatesView: View {
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(PurchaseStore.self) private var purchases
    @State private var allowNetwork = false

    var body: some View {
        let candidates = analysis.summary.duplicateCandidates
        let verifiedIDs = Set(analysis.verifiedDuplicates.flatMap { $0 })
        List {
            Section {
                Text("Photos that look the same aren't always the same file. Verifying compares every original file (including Live Photo videos, RAW+JPEG pairs and edits) byte for byte. Only exact matches are called duplicates.")
                    .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                Toggle("Download originals from iCloud if needed", isOn: $allowNetwork)
                    .font(.appSubheadline)
                Button {
                    Task { await analysis.verifyDuplicates(allowNetwork: allowNetwork) }
                } label: {
                    if analysis.verifyingDuplicates { ProgressView() } else { Text("Verify \(candidates.count) candidate groups") }
                }
                .disabled(candidates.isEmpty || analysis.verifyingDuplicates)
                if let note = analysis.verificationNote {
                    Text(note).font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                }
            }
            .listRowBackground(Color.appSurface)

            if !analysis.verifiedDuplicates.isEmpty {
                Section("Verified duplicates") {
                    ForEach(analysis.verifiedDuplicates, id: \.self) { ids in
                        GroupRow(group: SimilarGroup(ids: ids, suggestedKeeper: ids.first!, reason: .earliest,
                                                     isDuplicateCandidate: true), verified: true)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            let unverified = candidates.filter { !Set($0.ids).isSubset(of: verifiedIDs) }
            if !unverified.isEmpty {
                Section("Look identical · not verified") {
                    ForEach(unverified) { group in
                        GroupRow(group: group, verified: false)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            if candidates.isEmpty {
                MascotMessage(animated: .idle, title: "No duplicates found",
                              message: analysis.summary.isPartial ? "I'm still scanning." : "Nothing looks identical right now.")
                    .listRowBackground(Color.clear)
            }
        }
        .softAppBar()
        .scrollContentBackground(.hidden)
        .pageBackground()
        .navigationTitle("Verified Duplicates")
    }
}

// MARK: - Blurry candidates

struct BlurryView: View {
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(ReviewStore.self) private var reviews
    @Environment(PurchaseStore.self) private var purchases
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var model
    @State private var selection = Set<String>()
    @State private var selecting = false
    @State private var preview: PreviewRequest?

    var body: some View {
        let ids = analysis.summary.blurry
        VStack(spacing: 0) {
            Notice(kind: .info, text: "Suggestions only. Motion blur or soft focus can be on purpose. Screenshots, videos and favorites are left out.")
                .padding(.horizontal, Space.page).padding(.vertical, Space.xs)
            if ids.isEmpty {
                MascotMessage(animated: .idle, title: "Nothing blurry",
                              message: analysis.summary.isPartial ? "I'm still scanning." : "No photos look blurry right now.")
                Spacer()
            } else {
                AssetIDGrid(ids: ids, selection: $selection, selectionMode: selecting) { id in
                    preview = PreviewRequest(ids: ids, start: id)
                }
            }
        }
        .pageBackground()
        .navigationTitle("Blurry Candidates")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(selecting ? "Done" : "Select") { selecting.toggle(); selection.removeAll() }
                    .disabled(ids.isEmpty)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Review one by one") {
                    model.startSession(kind: .category, title: String(localized: "Blurry candidates"), assetIDs: ids)
                }
                .disabled(ids.isEmpty)
                Spacer()
                if selecting {
                    Button(purchases.isPro ? "Mark \(selection.count)" : "Mark \(selection.count) (Pro)") {
                        guard purchases.isPro else { router.showPaywall(.batchCleanup); return }
                        do { try reviews.decide(.marked, ids: Array(selection)); selection.removeAll() } catch { router.showPaywall(.dailyLimit) }
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
        .fullScreenCover(item: $preview) { AssetPreviewView(request: $0) }
    }
}

// MARK: - Videos (large, screen recordings, slo-mo)

enum VideoCategory: Hashable {
    case large, screenRecordings, slowMotion

    var title: LocalizedStringKey {
        switch self {
        case .large: "Large Videos"
        case .screenRecordings: "Screen Recordings"
        case .slowMotion: "Slo-mo Videos"
        }
    }

    var sessionTitle: String {
        switch self {
        case .large: String(localized: "Large videos")
        case .screenRecordings: String(localized: "Screen recordings")
        case .slowMotion: String(localized: "Slo-mo videos")
        }
    }

    var emptyTitle: LocalizedStringKey {
        switch self {
        case .large: "No videos"
        case .screenRecordings: "No screen recordings"
        case .slowMotion: "No slo-mo videos"
        }
    }

    var emptyMessage: LocalizedStringKey {
        switch self {
        case .large: "There are no videos Shotsy can see."
        case .screenRecordings: "Screen recordings you make will show up here."
        case .slowMotion: "Slo-mo videos you shoot will show up here."
        }
    }

    func videos(in summary: CategorySummary) -> [VideoItem] {
        switch self {
        case .large: summary.largeVideos
        case .screenRecordings: summary.screenRecordings
        case .slowMotion: summary.slowMotion
        }
    }
}

/// Videos sorted by measured size (largest first), then iCloud-only ones by duration. Mark or compress each.
struct VideoCategoryView: View {
    let kind: VideoCategory
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var reviews
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var model
    @State private var preview: PreviewRequest?
    /// Assets of the listed videos, resolved in one background fetch. Videos missing here get no row.
    @State private var assets: [String: PHAsset] = [:]
    @State private var loadedChange: Int?

    var body: some View {
        let videos = kind.videos(in: analysis.summary)
        let rows = videos.compactMap { video in assets[video.id].map { VideoRow(video: video, asset: $0) } }
        let unknown = videos.filter { $0.bytes == nil }.count
        List {
            if unknown > 0 {
                Notice(kind: .info, text: "\(unknown) videos are only in iCloud, so their size isn't known here. They're listed after, longest first, and this order may be incomplete.")
                    .listRowBackground(Color.clear)
            }
            if videos.isEmpty {
                MascotMessage(animated: .idle, title: kind.emptyTitle, message: kind.emptyMessage)
                    .listRowBackground(Color.clear)
            }
            ForEach(rows) { row in
                let video = row.video, asset = row.asset
                HStack(spacing: Space.s) {
                    AssetThumbnail(asset: asset, targetSide: 80)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onTapGesture { preview = PreviewRequest(ids: videos.map(\.id), start: video.id) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(video.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                             ?? String(localized: "Size unknown"))
                            .font(.appHeadline).foregroundStyle(Color.appText)
                        Text("\(AssetDescription.duration(video.duration)) · \(asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "")")
                            .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                    }
                    Spacer()
                    if reviews.decision(for: video.id) == .marked {
                        Image(systemName: "trash.circle.fill")
                            .foregroundStyle(Color.appDanger)
                            .accessibilityLabel("Selected for deletion")
                    }
                    Menu {
                        Button("Compress videos", systemImage: "arrow.down.right.and.arrow.up.left") {
                            router.cleanPath.append(CleanRoute.compress(video.id))
                        }
                        Button(reviews.decision(for: video.id) == .marked ? "Unmark" : "Mark for deletion", systemImage: "trash") {
                            if reviews.decision(for: video.id) == .marked { reviews.unmark([video.id]) }
                            else { do { try reviews.decide(.marked, ids: [video.id]) } catch { router.showPaywall(.dailyLimit) } }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3).frame(minWidth: Space.minTap, minHeight: Space.minTap)
                    }
                    .accessibilityLabel("Actions")
                }
                .listRowBackground(Color.appSurface)
            }
        }
        .softAppBar()
        .scrollContentBackground(.hidden)
        .pageBackground()
        .navigationTitle(kind.title)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Review one by one") {
                    model.startSession(kind: .category, title: kind.sessionTitle, assetIDs: videos.map(\.id))
                }
                .disabled(videos.isEmpty)
            }
        }
        .fullScreenCover(item: $preview) { AssetPreviewView(request: $0) }
        .task(id: "\(analysis.summaryRevision)-\(library.changeCount)") { await loadAssets() }
    }

    private struct VideoRow: Identifiable {
        var video: VideoItem
        var asset: PHAsset
        var id: String { video.id }
    }

    private func loadAssets() async {
        guard await BackgroundFetch.settle(changeCount: library.changeCount, loadedChangeCount: loadedChange) else { return }
        let change = library.changeCount
        let ids = kind.videos(in: analysis.summary).map(\.id)
        let canRead = library.access.canRead
        let map = await BackgroundFetch.run { canRead ? BackgroundFetch.assets(for: ids) : [:] }
        guard !Task.isCancelled else { return }
        assets = map
        loadedChange = change
    }
}

// MARK: - Bursts

/// Each burst keeps its best shot; the rest can be marked per burst or all at once.
struct BurstsView: View {
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(PurchaseStore.self) private var purchases
    @Environment(ReviewStore.self) private var reviews
    @Environment(Router.self) private var router
    /// Keeper overrides by burst ID.
    @State private var keepers: [String: String] = [:]
    @State private var message: String?

    var body: some View {
        let bursts = analysis.summary.bursts
        // Once per render: keeper and unmarked extras by burst ID, shared by the header and the rows.
        let plans = Dictionary(bursts.map { ($0.id, BurstPlan(keeper: keeper(for: $0), extras: unmarkedExtras(of: $0))) },
                               uniquingKeysWith: { first, _ in first })
        let ordered = bursts.compactMap { plans[$0.id] }
        let allExtras = ordered.flatMap(\.extras)
        List {
            Section {
                Text("Each burst keeps your pick, or the shot Photos picked. Tap a photo to keep it instead.")
                    .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                if !allExtras.isEmpty {
                    Button("Mark all \(allExtras.count) extras", systemImage: purchases.isPro ? "trash" : "lock") {
                        mark(allExtras, keepers: ordered.filter { !$0.extras.isEmpty }.map(\.keeper))
                    }
                    .buttonStyle(.secondary)
                }
                if let message { Text(message).font(.appFootnote).foregroundStyle(Color.appSecondaryText) }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            if bursts.isEmpty {
                MascotMessage(animated: .idle, title: "No bursts", message: "Burst photos you take will show up here.")
                    .listRowBackground(Color.clear)
            }
            ForEach(bursts) { burst in
                let plan = plans[burst.id] ?? BurstPlan(keeper: keeper(for: burst), extras: unmarkedExtras(of: burst))
                BurstRow(burst: burst, keeper: plan.keeper, extras: plan.extras,
                         onKeep: { keepers[burst.id] = $0 },
                         onMark: { mark($0, keepers: [keeper(for: burst)]) })
                    .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.page, bottom: Space.xs, trailing: Space.page))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .softAppBar()
        .pageBackground()
        .navigationTitle("Bursts")
    }

    private struct BurstPlan {
        var keeper: String
        var extras: [String]
    }

    private func keeper(for burst: BurstGroup) -> String {
        keepers[burst.id].flatMap { burst.ids.contains($0) ? $0 : nil } ?? burst.keeper
    }

    private func unmarkedExtras(of burst: BurstGroup) -> [String] {
        burst.extras(keeping: keeper(for: burst)).filter { reviews.decision(for: $0) != .marked }
    }

    /// Marks extras through the shared ledger (counts toward the free daily allowance) and keeps the keepers.
    /// Batch marking is Pro, like Similar; "Review one by one" stays free.
    private func mark(_ ids: [String], keepers: [String]) {
        guard !ids.isEmpty else { return }
        guard purchases.isPro else { router.showPaywall(.batchCleanup); return }
        do {
            try reviews.decide(.marked, ids: ids)
            try? reviews.decide(.keep, ids: keepers)
            message = String(localized: "Marked \(ids.count). Review them in Review deletions.")
        } catch {
            router.showPaywall(.dailyLimit)
        }
    }
}

private struct BurstRow: View {
    @Environment(PurchaseStore.self) private var purchases
    let burst: BurstGroup
    let keeper: String
    let extras: [String]
    let onKeep: (String) -> Void
    let onMark: ([String]) -> Void

    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var reviews
    @Environment(AppModel.self) private var model
    @State private var preview: PreviewRequest?
    /// The burst's photos, resolved once off the main thread (and again after library changes).
    @State private var assets: [PHAsset] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text("\(burst.ids.count) photos").font(.appHeadline).foregroundStyle(Color.appText)
                Spacer()
                if let date = burst.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Space.xs) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        let id = asset.localIdentifier
                        let marked = reviews.decision(for: id) == .marked
                        AssetThumbnail(asset: asset, targetSide: 130)
                            .frame(width: 100, height: 130)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                if marked || extras.contains(id) {
                                    Image(systemName: marked ? "trash.circle.fill" : "circle")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, marked ? Color.appDanger : .black.opacity(0.3))
                                        .padding(4)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if id == keeper {
                                    Text("Keep").font(.appCaption).foregroundStyle(.white)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Color.appSuccess, in: Capsule()).padding(4)
                                }
                            }
                            .onTapGesture { onKeep(id) }
                            .contextMenu {
                                Button("Make this the keeper", systemImage: "star") { onKeep(id) }
                                Button("Preview", systemImage: "eye") { preview = PreviewRequest(ids: burst.ids, start: id) }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(AssetDescription.label(for: asset))
                            .accessibilityValue(marked ? String(localized: "Selected for deletion") : (id == keeper ? String(localized: "Keeper") : ""))
                            .accessibilityAction(named: "Make keeper") { onKeep(id) }
                    }
                }
            }
            HStack {
                Button {
                    onMark(extras)
                } label: {
                    Label("Mark \(extras.count) extras", systemImage: purchases.isPro ? "trash" : "lock")
                }
                .buttonStyle(.secondary)
                .disabled(extras.isEmpty)
                Button("Review one by one") {
                    model.startSession(kind: .category, title: String(localized: "Bursts"), assetIDs: burst.ids)
                }
                .buttonStyle(.secondary)
            }
        }
        .card()
        .fullScreenCover(item: $preview) { AssetPreviewView(request: $0) }
        .task(id: LoadKey(ids: burst.ids, changeCount: library.changeCount)) { await loadAssets() }
    }

    nonisolated private struct LoadKey: Equatable {
        var ids: [String]
        var changeCount: Int
    }

    private func loadAssets() async {
        let ids = burst.ids
        let canRead = library.access.canRead
        let map = await BackgroundFetch.run { canRead ? BackgroundFetch.assets(for: ids) : [:] }
        guard !Task.isCancelled else { return }
        assets = ids.compactMap { map[$0] }
    }
}
