import Photos
import SwiftUI

/// Clean tab: months that still have unsorted items, as fanned cards. Newest first.
struct MonthsSection: View {
    let months: [MonthProgress]
    @Environment(Router.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicType

    /// The tab shows the most recent months; "See all" lists the rest.
    static let shownCount = 12

    var body: some View {
        if !months.isEmpty {
            let shown = Array(months.prefix(Self.shownCount))
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Months")
                        .font(.display(17, relativeTo: .headline))
                        .foregroundStyle(Color.appText)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if months.count > Self.shownCount {
                        Button("See all") { router.cleanPath.append(CleanRoute.months) }
                            .font(.appSubheadline.weight(.semibold))
                            .frame(minHeight: Space.minTap)
                    }
                }
                if dynamicType.isAccessibilitySize {
                    // Big text reads better as full-width rows than as a sideways strip.
                    VStack(spacing: Space.s) {
                        ForEach(shown) { MonthCard(month: $0, layout: .row) }
                    }
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Space.s) {
                            ForEach(shown) { MonthCard(month: $0, layout: .tile) }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .contentMargins(.horizontal, Space.page, for: .scrollContent)
                    .padding(.horizontal, -Space.page)
                }
            }
        }
    }
}

/// One month: fanned preview, title, and how much is left. Tapping starts (or resumes) its sort.
/// Equatable on its inputs, so an unchanged month skips re-rendering when the list refreshes.
struct MonthCard: View, Equatable {
    nonisolated enum Layout { case tile, row }

    let month: MonthProgress
    var layout: Layout = .tile
    @Environment(AppModel.self) private var model

    nonisolated static func == (lhs: MonthCard, rhs: MonthCard) -> Bool {
        lhs.month == rhs.month && lhs.layout == rhs.layout
    }

    var body: some View {
        Button {
            model.startMonth(month.section, assets: month.ids)
        } label: {
            Group {
                switch layout {
                case .tile:
                    VStack(alignment: .leading, spacing: Space.s) {
                        FannedStack(ids: month.previewIDs)
                            .frame(maxWidth: .infinity)
                            .padding(.top, Space.xxs)
                        text
                    }
                    .frame(width: 176, alignment: .leading)
                case .row:
                    HStack(spacing: Space.m) {
                        FannedStack(ids: month.previewIDs, cardSize: CGSize(width: 52, height: 68), spread: 22)
                        text
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .card(padding: Space.s)
            .contentShape(RoundedRectangle(cornerRadius: Space.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(month.section.title)
                .font(.appHeadline)
                .foregroundStyle(Color.appText)
                .lineLimit(2)
            Text("\(month.unsorted) left of \(month.total)")
                .font(.appFootnote)
                .foregroundStyle(Color.appSecondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, Space.xxs)
    }
}

/// "See all": every month with something left to sort, newest first.
struct AllMonthsView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var reviews
    @Environment(Router.self) private var router
    @State private var months: [MonthProgress]?
    @State private var snapshot: MonthSnapshot?
    @State private var loadedChange: Int?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Space.s) {
                if let months, months.isEmpty {
                    MascotMessage(animated: .idle, title: "All sorted",
                                  message: "You've reviewed everything Shotsy can see. New photos will show up here.")
                }
                ForEach(months ?? []) { MonthCard(month: $0, layout: .row) }
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, Space.xxl)
        }
        .softAppBar()
        .pageBackground()
        .navigationTitle("Months")
        .overlay { if months == nil { ProgressView() } }
        // Paused while a sort session is open (every swipe bumps the review revision); runs once when it closes.
        .task(id: "\(library.changeCount)-\(reviews.revision)-\(router.session == nil)") { await refresh() }
    }

    private func refresh() async {
        guard router.session == nil else { return }
        guard await BackgroundFetch.settle(changeCount: library.changeCount, loadedChangeCount: loadedChange) else { return }
        let change = library.changeCount
        let all = library.allAssets
        let decisions = reviews.ledger.decisions
        let cached = loadedChange == change ? snapshot : nil
        let (newSnapshot, found) = await BackgroundFetch.run {
            let s = cached ?? MonthSnapshot.read(all)
            return (s, MonthPlanner.unsorted(s.months, decisions: decisions))
        }
        guard !Task.isCancelled else { return }
        snapshot = newSnapshot
        months = found
        loadedChange = change
    }
}
