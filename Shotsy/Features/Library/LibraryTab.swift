import Photos
import SwiftUI

enum LibraryRoute: Hashable {
    case people
    case person(UUID)
    case assets(title: String, ids: [String])
    case album(String)
}

/// Visible library slice: a fetch result plus an optional index map (for filters PhotoKit can't express).
struct LibrarySlice {
    var fetch = PHFetchResult<PHAsset>()
    var map: [Int]?
    var sections: [MonthSection] = []

    var count: Int { map?.count ?? fetch.count }
    func asset(at position: Int) -> PHAsset { fetch.object(at: map?[position] ?? position) }
    func ids(in range: Range<Int>) -> [String] { range.map { asset(at: $0).localIdentifier } }
}

struct LibraryTab: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var reviews
    @Environment(PeopleStore.self) private var people
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dynamicTypeSize) private var dynamicType

    @State private var filter: MediaFilter = .all
    @State private var personFilter: UUID?
    @State private var ascending = false
    @State private var slice = LibrarySlice()
    @State private var loading = true
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var query = ""
    @State private var preview: PreviewRequest?
    @State private var showAlbumSheet = false
    @State private var toast: String?
    @State private var loadedChange: Int?

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.libraryPath) {
            Group {
                if !library.access.canRead {
                    ScrollView { AccessBanner().padding(Space.page) }
                } else if !query.isEmpty {
                    LibrarySearchResults(query: query, slice: slice)
                } else {
                    grid
                }
            }
            .pageBackground()
            .navigationTitle("Library")
            .searchable(text: $query, prompt: "Albums, dates, screenshot text")
            .toolbar { toolbar }
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .people: PeopleView()
                case .person(let id): PersonDetailView(personID: id)
                case .assets(let title, let ids): AssetListScreen(title: title, ids: ids)
                case .album(let id): AlbumDetailView(albumID: id)
                }
            }
            .task(id: "\(filter)-\(personFilter?.uuidString ?? "")-\(ascending)-\(library.changeCount)-\(filter == .unreviewed ? reviews.revision : 0)") {
                await reload()
            }
            .sheet(isPresented: $showAlbumSheet) {
                AddToAlbumSheet(assetIDs: Array(selection)) { title in
                    flash(String(localized: "Added to \(title)"))
                    selection.removeAll()
                }
            }
            .fullScreenCover(item: $preview) { AssetPreviewView(request: $0) }
        }
    }

    // MARK: Grid

    private var grid: some View {
        GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.s) {
                    if !selecting && personFilter == nil {
                        PeopleEntryRow()
                            .padding(.horizontal, Space.page)
                    }
                    if library.access == .limited {
                        AccessBanner().padding(.horizontal, Space.page)
                    }
                    if let personFilter, let person = people.people.first(where: { $0.id == personFilter }) {
                        Notice(kind: .info, text: "Showing photos with \(person.displayName)", actionTitle: "Clear") {
                            self.personFilter = nil
                        }
                        .padding(.horizontal, Space.page)
                    }
                    if loading && slice.count == 0 {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, Space.xxl)
                    } else if slice.count == 0 {
                        MascotMessage(animated: .idle, title: "Nothing here", message: "No items match this filter.")
                    }
                    let columns = GridMetrics.columns(for: geo.size.width, dynamicType: dynamicType)
                    ForEach(slice.sections) { section in
                        Section {
                            LazyVGrid(columns: columns, spacing: 2) {
                                ForEach(section.range, id: \.self) { position in
                                    let asset = slice.asset(at: position)
                                    let id = asset.localIdentifier
                                    AssetCell(asset: asset, isSelected: selection.contains(id), selectionMode: selecting,
                                              decision: reviews.decision(for: id), side: geo.size.width / CGFloat(columns.count))
                                        .onTapGesture {
                                            if selecting { toggle(id) } else {
                                                preview = PreviewRequest(ids: slice.ids(in: section.range), start: id)
                                            }
                                        }
                                }
                            }
                        } header: {
                            MonthHeader(section: section, ids: { slice.ids(in: section.range) })
                        }
                    }
                }
                .padding(.bottom, Space.xxl)
            }
            .softAppBar()
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(.appFootnote).padding(Space.s)
                        .background(.regularMaterial, in: Capsule()).padding(.bottom, Space.l)
                        .transition(.opacity)
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        SettingsToolbarButton { router.sheet = .settings }
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Show", selection: $filter) {
                    ForEach(MediaFilter.allCases) { f in Label(String(localized: f.title), systemImage: f.systemImage).tag(f) }
                }
                let named = people.people.filter { $0.name != nil }
                if !named.isEmpty {
                    Picker("Person", selection: $personFilter) {
                        Text("Anyone").tag(UUID?.none)
                        ForEach(named) { Text($0.displayName).tag(UUID?.some($0.id)) }
                    }
                }
                Picker("Order", selection: $ascending) {
                    Text("Newest first").tag(false)
                    Text("Oldest first").tag(true)
                }
            } label: {
                Label("Filter", systemImage: filter == .all && personFilter == nil
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
        }
        // Multi-select for Share, Favorite, Add to Album and Mark for deletion; hidden until photos are connected.
        if library.access.canRead {
            ToolbarItem(placement: .primaryAction) {
                Button(selecting ? LocalizedStringKey("Done") : LocalizedStringKey("Select")) {
                    selecting.toggle()
                    selection.removeAll()
                }
            }
        }
        if selecting {
            ToolbarItemGroup(placement: .bottomBar) {
                ShareAssetsButton(ids: Array(selection))
                Spacer()
                let selected = library.assets(for: Array(selection))
                let allFavorite = !selected.isEmpty && selected.allSatisfy(library.isFavorite)
                Button(allFavorite ? "Unfavorite" : "Favorite", systemImage: allFavorite ? "heart.slash" : "heart") {
                    Task { try? await library.setFavorite(selected, !allFavorite) }
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button("Add to Album", systemImage: "rectangle.stack.badge.plus") { showAlbumSheet = true }
                    .disabled(selection.isEmpty)
                Spacer()
                Button("Mark for deletion", systemImage: "trash") {
                    do {
                        try reviews.decide(.marked, ids: Array(selection))
                        flash(String(localized: "Marked \(selection.count). Nothing is deleted until you review."))
                        selection.removeAll()
                    } catch {
                        router.showPaywall(.dailyLimit)
                    }
                }
                .disabled(selection.isEmpty)
            }
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func flash(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { toast = nil }
        }
    }

    private func reload() async {
        guard await BackgroundFetch.settle(changeCount: library.changeCount, loadedChangeCount: loadedChange) else { return }
        let change = library.changeCount
        loading = true
        let fetch = library.fetch(filter, ascending: ascending)
        // "Unreviewed" (the fetch is every photo/video) is filtered in the background pass below.
        let reviewed: [String: ReviewDecision]? = filter == .unreviewed ? reviews.ledger.decisions : nil
        let person: Set<String>? = personFilter.map { Set(people.assetIDs(of: $0)) }
        let result = fetch
        let selected = selection
        let (map, sections, kept) = await Task.detached(priority: .userInitiated) { () -> ([Int]?, [MonthSection], Set<String>) in
            var dates: [Date?] = []
            var kept = Set<String>()
            var map: [Int]? = reviewed == nil && person == nil ? nil : []
            dates.reserveCapacity(result.count)
            result.enumerateObjects { a, i, _ in
                if map != nil {
                    let id = a.localIdentifier
                    if let reviewed, reviewed[id] != nil { return }
                    if let person, !person.contains(id) { return }
                    map?.append(i)
                }
                if !selected.isEmpty, selected.contains(a.localIdentifier) { kept.insert(a.localIdentifier) }
                dates.append(a.creationDate)
            }
            return (map, LibraryIndex.months(dates: dates), kept)
        }.value
        guard !Task.isCancelled else { return }
        loadedChange = change
        slice = LibrarySlice(fetch: fetch, map: map, sections: sections)
        // Selected items that left the slice drop out (`kept` comes from the background pass).
        selection.subtract(selected.subtracting(kept))
        loading = false
    }
}

private struct MonthHeader: View {
    let section: MonthSection
    let ids: () -> [String]
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Text(section.title).font(.appHeadline).foregroundStyle(Color.appText)
            Text("\(section.count)").font(.appFootnote).foregroundStyle(Color.appSecondaryText)
            Spacer()
            Button("Sort") { model.startMonth(section, assets: ids()) }
                .font(.appSubheadline.weight(.semibold))
                .frame(minHeight: Space.minTap)
                .accessibilityLabel("Sort \(section.title)")
        }
        .padding(.horizontal, Space.page)
        .padding(.top, Space.s)
    }
}

private struct PeopleEntryRow: View {
    @Environment(PeopleStore.self) private var people
    @Environment(Router.self) private var router

    var body: some View {
        Button { router.libraryPath.append(LibraryRoute.people) } label: {
            HStack(spacing: Space.s) {
                HStack(spacing: -10) {
                    ForEach(people.people.prefix(3)) { p in
                        if let face = p.coverFace {
                            FaceCropView(assetID: face.assetID, box: face.box)
                                .frame(width: 34, height: 34)
                                .overlay(Circle().stroke(Color.appSurface, lineWidth: 2))
                        }
                    }
                    if people.people.isEmpty {
                        Image(systemName: "person.2.crop.square.stack").font(.title2).foregroundStyle(Color.appAccent)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("People").font(.appHeadline).foregroundStyle(Color.appText)
                    Text(people.people.isEmpty ? "Tag the people in your photos" : "\(people.people.count) people")
                        .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.appSecondaryText)
            }
            .card(padding: Space.s)
        }
        .buttonStyle(.plain)
    }
}

/// Search across album names, dates (months/years), people names, and screenshot text (Pro).
private struct LibrarySearchResults: View {
    let query: String
    let slice: LibrarySlice

    @Environment(AlbumService.self) private var albums
    @Environment(ScreenshotStore.self) private var screenshots
    @Environment(PeopleStore.self) private var people
    @Environment(PurchaseStore.self) private var purchases
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(Router.self) private var router
    @Environment(PhotoLibrary.self) private var library
    @State private var textHits: [String] = []
    @State private var allAlbums: [AlbumInfo] = []

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let albumHits = allAlbums.filter { $0.title.localizedStandardContains(q) }
        let monthHits = slice.sections.filter { $0.title.localizedStandardContains(q) || $0.key.contains(q) }
        let peopleHits = people.people.filter { ($0.name ?? "").localizedStandardContains(q) }
        List {
            if !albumHits.isEmpty {
                Section("Albums") {
                    ForEach(albumHits) { album in
                        NavigationLink(value: LibraryRoute.album(album.id)) {
                            LabeledContent(album.title, value: "\(album.count)")
                        }
                    }
                }
            }
            if !monthHits.isEmpty {
                Section("Dates") {
                    ForEach(monthHits) { section in
                        NavigationLink(value: LibraryRoute.assets(title: section.title, ids: slice.ids(in: section.range))) {
                            LabeledContent(section.title, value: "\(section.count)")
                        }
                    }
                }
            }
            if !peopleHits.isEmpty {
                Section("People") {
                    ForEach(peopleHits) { p in
                        NavigationLink(value: LibraryRoute.person(p.id)) { LabeledContent(p.displayName, value: "\(p.photoCount)") }
                    }
                }
            }
            Section {
                if purchases.isPro {
                    if textHits.isEmpty {
                        Text("No screenshot text matches.").foregroundStyle(Color.appSecondaryText)
                    } else {
                        NavigationLink(value: LibraryRoute.assets(title: String(localized: "“\(q)” in screenshots"), ids: textHits)) {
                            LabeledContent("Screenshots containing “\(q)”", value: "\(textHits.count)")
                        }
                    }
                } else {
                    Button("Search text in screenshots with Shotsy Pro") { router.showPaywall(.ocrSearch) }
                }
            } header: {
                Text("Screenshot text")
            } footer: {
                if purchases.isPro {
                    Text("Read on this iPhone. \(screenshots.indexedCount()) screenshots indexed so far. Recognized languages: \(analysis.supportedOCRLanguages.prefix(12).joined(separator: ", ")).")
                }
            }
        }
        .softAppBar()
        // Album counts are read once per search session, off the main thread, not on every keystroke.
        .task(id: library.changeCount) { allAlbums = await albums.userAlbums() }
        .task(id: q) {
            var hits: [String] = []
            if purchases.isPro { hits = await screenshots.searchInBackground(q) }
            if !Task.isCancelled { textHits = hits }
        }
    }
}

/// Simple titled grid for search results and months.
struct AssetListScreen: View {
    let title: String
    let ids: [String]
    @State private var selection = Set<String>()
    @State private var preview: PreviewRequest?

    var body: some View {
        AssetIDGrid(ids: ids, selection: $selection, selectionMode: false) { preview = PreviewRequest(ids: ids, start: $0) }
            .pageBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $preview) { AssetPreviewView(request: $0) }
    }
}
