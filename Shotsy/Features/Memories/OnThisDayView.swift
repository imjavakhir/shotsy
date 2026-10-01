import Photos
import SwiftUI

/// Runs off the main thread; callers check Photos access on the main actor first.
nonisolated enum OnThisDayLoader {
    struct YearGroup: Identifiable, Sendable {
        var year: Int
        var ids: [String]
        var id: Int { year }
    }

    static func load(decisions: [String: ReviewDecision], spanDays: Int = 0,
                     includeScreenshots: Bool = false, now: Date = .now) -> [YearGroup] {
        let oldestOptions = PhotoLibrary.options(predicate: PhotoLibrary.photosAndVideos, ascending: true)
        oldestOptions.fetchLimit = 1
        guard let oldest = PHAsset.fetchAssets(with: oldestOptions).firstObject?.creationDate else { return [] }
        return OnThisDay.ranges(today: now, earliest: oldest, spanDays: spanDays).compactMap { range in
            var ids: [String] = []
            PHAsset.fetchAssets(with: PhotoLibrary.options(predicate: OnThisDay.predicate(for: range, includeScreenshots: includeScreenshots)))
                .enumerateObjects { a, _, _ in
                    // Items queued for deletion are left out.
                    if decisions[a.localIdentifier] != .marked { ids.append(a.localIdentifier) }
                }
            return ids.isEmpty ? nil : YearGroup(year: range.year, ids: ids)
        }
    }

    static func count(decisions: [String: ReviewDecision]) -> Int {
        load(decisions: decisions).reduce(0) { $0 + $1.ids.count }
    }
}

/// Same day in earlier years. Viewing never changes review state.
struct OnThisDayView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var reviews
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicType
    @AppStorage("onThisDaySpan") private var span = 0
    @AppStorage("onThisDayScreenshots") private var includeScreenshots = false
    @State private var groups: [OnThisDayLoader.YearGroup] = []
    @State private var preview: PreviewRequest?
    @State private var loadedChange: Int?

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.l, pinnedViews: []) {
                    Text(Date.now.formatted(.dateTime.month(.wide).day()) + (span > 0 ? " ± \(span)" : ""))
                        .font(.appSubheadline).foregroundStyle(Color.appSecondaryText)
                    if groups.isEmpty {
                        MascotMessage(animated: .idle, title: "No memories for today",
                                      message: "Nothing from this date in earlier years. Try widening the range.")
                    }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            HStack {
                                Text(verbatim: "\(group.year)").font(.display(20, relativeTo: .title3)).foregroundStyle(Color.appText)
                                Text(yearsAgo(group.year)).font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                                Spacer()
                                Button("Review") {
                                    model.startSession(kind: .onThisDay, title: String(localized: "On This Day \(group.year)"), assetIDs: group.ids)
                                }
                                .font(.appSubheadline.weight(.semibold))
                                .frame(minHeight: Space.minTap)
                            }
                            let assets = library.assets(for: group.ids)
                            LazyVGrid(columns: GridMetrics.columns(for: geo.size.width - 2 * Space.page, dynamicType: dynamicType), spacing: 2) {
                                ForEach(assets, id: \.localIdentifier) { asset in
                                    AssetCell(asset: asset)
                                        .onTapGesture { preview = PreviewRequest(ids: group.ids, start: asset.localIdentifier) }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, Space.page)
                .padding(.bottom, Space.xxl)
            }
            .softAppBar()
        }
        .pageBackground()
        .navigationTitle("On This Day")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Range", selection: $span) {
                        Text("Exact day").tag(0)
                        Text("± 3 days").tag(3)
                        Text("± 1 week").tag(7)
                    }
                    Toggle("Include screenshots", isOn: $includeScreenshots)
                } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                }
            }
        }
        .task(id: "\(span)-\(includeScreenshots)-\(library.changeCount)") { await load() }
        .fullScreenCover(item: $preview) { AssetPreviewView(request: $0) }
    }

    private func load() async {
        guard await BackgroundFetch.settle(changeCount: library.changeCount, loadedChangeCount: loadedChange) else { return }
        let change = library.changeCount
        guard library.access.canRead, library.allAssets.count > 0 else { groups = []; loadedChange = change; return }
        let decisions = reviews.ledger.decisions
        let span = span, includeScreenshots = includeScreenshots
        let loaded = await BackgroundFetch.run {
            OnThisDayLoader.load(decisions: decisions, spanDays: span, includeScreenshots: includeScreenshots)
        }
        guard !Task.isCancelled else { return }
        groups = loaded
        loadedChange = change
    }

    private func yearsAgo(_ year: Int) -> String {
        let n = Calendar.current.component(.year, from: .now) - year
        return String(localized: "\(n) years ago")
    }
}
