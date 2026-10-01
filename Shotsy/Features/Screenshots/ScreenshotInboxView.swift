import Photos
import SwiftUI

/// One home for screenshots. Categories and labels are local Shotsy metadata, not Photos categories.
struct ScreenshotInboxView: View {
    enum Filter: Hashable {
        case all, pinned, unsorted, needsIndexing
        case category(ScreenshotCategory)
        case label(String)
    }

    @Environment(PhotoLibrary.self) private var library
    @Environment(ScreenshotStore.self) private var store
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(SettingsStore.self) private var settings
    @Environment(PurchaseStore.self) private var purchases
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var model
    @Environment(AlbumService.self) private var albums

    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var selection = Set<String>()
    @State private var selecting = false
    @State private var detail: String?
    @State private var shown: [String] = []
    @State private var allIDs: [String] = []
    @State private var indexedCount = 0
    @State private var labelPrompt = false
    @State private var newLabel = ""
    @State private var albumMessage: String?
    @State private var labels: [String] = []
    @State private var loadedChange: Int?

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            statusBar
            if shown.isEmpty {
                MascotMessage(animated: .idle, title: emptyTitle, message: emptyMessage)
                Spacer()
            } else {
                AssetIDGrid(ids: shown, selection: $selection, selectionMode: selecting) { detail = $0 }
            }
        }
        .pageBackground()
        .navigationTitle("Screenshot Inbox")
        .searchable(text: $query, prompt: purchases.isPro ? "Search text in screenshots" : "Text search is in Pro")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(selecting ? "Done Selecting" : "Select", systemImage: "checkmark.circle") {
                        selecting.toggle(); selection.removeAll()
                    }
                    Button("Review these one by one", systemImage: "hand.draw") {
                        model.startSession(kind: .screenshots, title: String(localized: "Screenshots"), assetIDs: shown)
                    }
                    if case .category(let c) = filter {
                        Button("Create Photos album “\(String(localized: c.title))”", systemImage: "rectangle.stack.badge.plus") {
                            Task { await createAlbum(named: String(localized: c.title)) }
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
            if selecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    Menu("Category") {
                        ForEach(ScreenshotCategory.allCases) { c in
                            Button(String(localized: c.title)) { store.setCategory(c, for: Array(selection)) }
                        }
                        Button("Clear correction") { store.setCategory(nil, for: Array(selection)) }
                    }
                    Spacer()
                    Button("Label") { labelPrompt = true }
                    Spacer()
                    Button("Pin") { store.setPinned(true, for: Array(selection)) }
                }
            }
        }
        .alert("Add label", isPresented: $labelPrompt) {
            TextField("Label", text: $newLabel)
            Button("Add") { store.addLabel(newLabel, to: Array(selection)); newLabel = "" }
            Button("Cancel", role: .cancel) {}
        }
        .alert(albumMessage ?? "", isPresented: Binding(get: { albumMessage != nil }, set: { if !$0 { albumMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .sheet(item: Binding(get: { detail.map { PreviewRequest(ids: shown, start: $0) } }, set: { detail = $0?.start })) { request in
            ScreenshotDetailView(assetID: request.start)
        }
        // Store edits bump `store.revision`, which reloads. Scan progress doesn't; only a finished scan does.
        .task(id: "\(library.changeCount)-\(store.revision)-\(analysis.phase == .complete)-\(filter)-\(query)-\(purchases.isPro)") {
            await reload()
        }
    }

    private var suggestionsOn: Bool { purchases.isPro && settings.ocrEnabled }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.xs) {
                chip("All", .all)
                chip("Pinned", .pinned)
                ForEach(ScreenshotCategory.allCases) { c in chip(LocalizedStringKey(String(localized: c.title)), .category(c)) }
                chip("Unsorted", .unsorted)
                if suggestionsOn { chip("Not indexed", .needsIndexing) }
                ForEach(labels, id: \.self) { l in chip(LocalizedStringKey("#\(l)"), .label(l)) }
            }
            .padding(.horizontal, Space.page)
            .padding(.vertical, Space.xs)
        }
    }

    private func chip(_ title: LocalizedStringKey, _ value: Filter) -> some View {
        Button { filter = value } label: {
            Text(title)
                .font(.appSubheadline.weight(.medium))
                .padding(.horizontal, Space.s)
                .frame(minHeight: 36)
                .background(filter == value ? Color.appAccentFill : Color.appChip, in: Capsule())
                .foregroundStyle(filter == value ? .white : Color.appText)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == value ? .isSelected : [])
    }

    @ViewBuilder private var statusBar: some View {
        Group {
            if !purchases.isPro {
                Notice(kind: .info, text: "Label and pin screenshots for free. Automatic categories and text search come with Shotsy Pro.",
                       actionTitle: "See Pro", action: { router.showPaywall(.categorySuggestions) })
            } else if !settings.ocrEnabled {
                Notice(kind: .info, text: "Screenshot text reading is off in Settings.")
            } else if indexedCount < allIDs.count {
                Notice(kind: .info, text: "Read text in \(indexedCount) of \(allIDs.count) screenshots. Suggestions are English-keyword based; other languages show as Other.")
            }
        }
        .padding(.horizontal, Space.page)
        .padding(.bottom, Space.xs)
    }

    private var emptyTitle: LocalizedStringKey { query.isEmpty ? "No screenshots here" : "No matches" }
    private var emptyMessage: LocalizedStringKey {
        query.isEmpty ? "Try another filter." : "No screenshot text matches “\(query)”. Items not indexed yet can't match."
    }

    private func reload() async {
        guard await BackgroundFetch.settle(changeCount: library.changeCount, loadedChangeCount: loadedChange) else { return }
        let change = library.changeCount
        let canRead = library.access.canRead
        let query = query
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        async let fetchedIDs = BackgroundFetch.run {
            canRead ? BackgroundFetch.identifiers(in: BackgroundFetch.fetch(.screenshots)) : []
        }
        async let fetchedSnapshot = store.snapshot()
        let (ids, snapshot) = await (fetchedIDs, fetchedSnapshot)
        var hits = Set<String>()
        if searching && purchases.isPro { hits = Set(await store.searchInBackground(query)) }
        guard !Task.isCancelled else { return }
        allIDs = ids
        indexedCount = snapshot.indexedCount
        labels = snapshot.labels
        let meta = snapshot.meta
        let index = snapshot.index
        let suggestionsOn = suggestionsOn
        func category(_ id: String) -> ScreenshotCategory? {
            snapshot.category(of: id, suggestionsEnabled: suggestionsOn)
        }
        var result: [String]
        switch filter {
        case .all: result = ids
        case .pinned: result = ids.filter { meta[$0]?.isPinned == true }
        case .unsorted: result = ids.filter { category($0) == nil }
        case .needsIndexing: result = ids.filter { index[$0] == nil || index[$0]?.failed == true }
        case .category(let c): result = ids.filter { category($0) == c }
        case .label(let l): result = ids.filter { meta[$0]?.labels.contains(l) == true }
        }
        if searching {
            result = purchases.isPro ? result.filter(hits.contains) : []
        }
        // Pinned first.
        shown = result.filter { meta[$0]?.isPinned == true } + result.filter { meta[$0]?.isPinned != true }
        loadedChange = change
    }

    /// Explicit action: creates a regular Photos album with the current screenshots. It won't update itself.
    private func createAlbum(named name: String) async {
        do {
            if let id = try await albums.createAlbum(named: name), let album = albums.album(id: id) {
                try await albums.add(library.assets(for: shown), to: album)
                albumMessage = String(localized: "Created the Photos album “\(name)” with \(shown.count) screenshots. It won't update automatically.")
            }
        } catch {
            albumMessage = error.localizedDescription
        }
    }
}

struct ScreenshotDetailView: View {
    let assetID: String

    @Environment(ScreenshotStore.self) private var store
    @Environment(PhotoLibrary.self) private var library
    @Environment(PurchaseStore.self) private var purchases
    @Environment(SettingsStore.self) private var settings
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var newLabel = ""
    @State private var preview: PreviewRequest?

    var body: some View {
        let meta = store.meta(for: assetID)
        let index = store.index(for: assetID)
        let suggested = index?.suggestedCategoryRaw.flatMap(ScreenshotCategory.init(rawValue:))
        let user = meta?.userCategoryRaw.flatMap(ScreenshotCategory.init(rawValue:))
        NavigationStack {
            Form {
                if let asset = library.asset(for: assetID) {
                    Section {
                        AssetThumbnail(asset: asset, targetSide: 400, contentMode: .fit)
                            .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 360)
                            .onTapGesture { preview = PreviewRequest(ids: [assetID], start: assetID) }
                    }
                }
                Section {
                    Picker("Category", selection: Binding(
                        get: { user ?? (purchases.isPro ? suggested : nil) },
                        set: { store.setCategory($0, for: [assetID]) })) {
                        Text("None").tag(ScreenshotCategory?.none)
                        ForEach(ScreenshotCategory.allCases) { Text($0.title).tag(ScreenshotCategory?.some($0)) }
                    }
                    if user == nil, let suggested, purchases.isPro {
                        Text("Suggested from the text: \(String(localized: suggested.title)). Change it any time.")
                            .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                    }
                    if user != nil {
                        Button("Use suggestion instead") { store.setCategory(nil, for: [assetID]) }
                    }
                    Toggle("Pinned", isOn: Binding(get: { meta?.isPinned ?? false },
                                                   set: { store.setPinned($0, for: [assetID]) }))
                } footer: {
                    Text("Categories and labels are Shotsy's own. They don't change Apple Photos.")
                }
                Section("Labels") {
                    ForEach(meta?.labels ?? [], id: \.self) { label in
                        Text(label).swipeActions { Button("Remove", role: .destructive) { store.removeLabel(label, from: assetID) } }
                    }
                    HStack {
                        TextField("Add a label", text: $newLabel)
                        Button("Add") { store.addLabel(newLabel, to: [assetID]); newLabel = "" }
                            .disabled(newLabel.trimmedNonEmpty == nil)
                    }
                }
                if purchases.isPro {
                    Section("Text") {
                        if let index, !index.failed, !index.text.isEmpty {
                            Text(index.text).font(.appCallout).textSelection(.enabled)
                            ForEach(index.links, id: \.self) { link in
                                if let url = URL(string: link) {
                                    // Opens only when tapped. Never fetched automatically.
                                    Link(destination: url) { Label(link, systemImage: "link").lineLimit(1) }
                                }
                            }
                        } else if index?.failed == true {
                            Text("Couldn't read text yet. It may be in iCloud; I'll retry later.")
                                .foregroundStyle(Color.appSecondaryText)
                        } else if index != nil {
                            Text("No text found.").foregroundStyle(Color.appSecondaryText)
                        } else {
                            Text(settings.ocrEnabled ? "Not read yet." : "Text reading is off in Settings.")
                                .foregroundStyle(Color.appSecondaryText)
                        }
                    }
                } else {
                    Section {
                        Button("Unlock text search and suggestions") { dismiss(); router.showPaywall(.ocrSearch) }
                    }
                }
            }
            .softAppBar()
            .navigationTitle("Screenshot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fullScreenCover(item: $preview) { AssetPreviewView(request: $0) }
        }
    }
}
