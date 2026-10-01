import Photos
import SwiftUI

/// Builds the rule-evaluation snapshot from the library and Shotsy's local index.
enum SmartCollectionEvaluator {
    /// Reads every asset; call it off the main thread.
    nonisolated static func facts(in all: PHFetchResult<PHAsset>) -> [AssetFacts] {
        var facts: [AssetFacts] = []
        facts.reserveCapacity(all.count)
        all.enumerateObjects { a, _, _ in
            facts.append(AssetFacts(id: a.localIdentifier, isVideo: a.mediaType == .video, isScreenshot: a.isScreenshot,
                                    isLivePhoto: a.isLivePhoto, creationDate: a.creationDate, isFavorite: a.isFavorite,
                                    duration: a.duration))
        }
        return facts
    }

    /// Album membership and the screenshot index are read off the main thread.
    static func context(for rules: [SmartRule], reviews: ReviewStore, screenshots: ScreenshotStore,
                        analysis: AnalysisCoordinator, suggestionsEnabled: Bool) async -> RuleContext {
        var ctx = RuleContext()
        ctx.decisions = reviews.ledger.decisions
        var screenshotSnapshot: ScreenshotSnapshot?
        for rule in rules {
            switch rule {
            case .inAlbum(let id, _):
                ctx.albumMembers[id] = await BackgroundFetch.run { AlbumService.memberIDs(albumID: id) }
            case .screenshotCategory, .screenshotLabel, .pinned:
                guard screenshotSnapshot == nil else { break }
                let snapshot = await screenshots.snapshot()
                screenshotSnapshot = snapshot
                for (id, m) in snapshot.meta {
                    ctx.screenshotLabels[id] = m.labels
                    if m.isPinned { ctx.pinned.insert(id) }
                }
                for id in Set(snapshot.meta.keys).union(snapshot.index.keys) {
                    if let c = snapshot.category(of: id, suggestionsEnabled: suggestionsEnabled) {
                        ctx.screenshotCategories[id] = c
                    }
                }
            case .videoLargerThan:
                for v in analysis.summary.largeVideos { if let b = v.bytes { ctx.videoBytes[v.id] = b } }
            default:
                break
            }
        }
        return ctx
    }
}

struct SmartCollectionDetailView: View {
    let collectionID: UUID

    @Environment(SmartCollectionStore.self) private var store
    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var reviews
    @Environment(AlbumService.self) private var albums
    @Environment(ScreenshotStore.self) private var screenshots
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(PurchaseStore.self) private var purchases
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var result = SmartMatchResult(matches: [], unknown: 0)
    @State private var loading = true
    @State private var editing: SmartCollection?
    @State private var selection = Set<String>()
    @State private var preview: PreviewRequest?
    @State private var message: String?
    @State private var confirmSnapshot = false
    @State private var loadedChange: Int?

    var body: some View {
        let collection = store.collections.first { $0.id == collectionID }
        VStack(alignment: .leading, spacing: 0) {
            if let collection {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(collection.rules.map(SmartRuleEngine.describe).joined(separator: collection.matchAll ? " · and · " : " · or · "))
                        .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                    Text(loading ? String(localized: "Updating…") : String(localized: "\(result.matches.count) items"))
                        .font(.appSubheadline.weight(.semibold))
                    if result.unknown > 0 {
                        Text("\(result.unknown) items couldn't be checked yet (not indexed, or size unknown). They're not counted as matches.")
                            .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                    }
                    if let message { Text(message).font(.appFootnote).foregroundStyle(Color.appSecondaryText) }
                }
                .padding(.horizontal, Space.page).padding(.vertical, Space.xs)
            }
            if !loading && result.matches.isEmpty {
                MascotMessage(animated: .idle, title: "No matches right now", message: "This collection updates as your library changes.")
                Spacer()
            } else {
                AssetIDGrid(ids: result.matches, selection: $selection, selectionMode: false) {
                    preview = PreviewRequest(ids: result.matches, start: $0)
                }
            }
        }
        .pageBackground()
        .navigationTitle(collection?.name ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Edit rules", systemImage: "slider.horizontal.3") { editing = collection }
                    Button("Review one by one", systemImage: "hand.draw") {
                        model.startSession(kind: .category, title: collection?.name ?? "", assetIDs: result.matches)
                    }
                    Button("Save as Photos album…", systemImage: "rectangle.stack.badge.plus") { confirmSnapshot = true }
                    if let collection {
                        Button("Delete collection", systemImage: "trash", role: .destructive) { store.delete(collection); dismiss() }
                    }
                } label: { Label("Actions", systemImage: "ellipsis.circle") }
            }
        }
        .confirmationDialog("Save as a Photos album?", isPresented: $confirmSnapshot, titleVisibility: .visible) {
            Button("Create album with \(result.matches.count) items") { Task { await snapshot(name: collection?.name ?? "") } }
        } message: {
            Text("This makes a regular Photos album with today's matches. Unlike the Smart Collection, it won't update.")
        }
        .task(id: "\(collection?.rules.hashValue ?? 0)-\(collection?.matchAll ?? true)-\(library.changeCount)-\(reviews.revision)-\(screenshots.revision)") {
            guard let collection,
                  await BackgroundFetch.settle(changeCount: library.changeCount, loadedChangeCount: loadedChange) else { return }
            let change = library.changeCount
            loading = true
            let all = library.allAssets
            async let facts = BackgroundFetch.run { SmartCollectionEvaluator.facts(in: all) }
            let ctx = await SmartCollectionEvaluator.context(for: collection.rules, reviews: reviews, screenshots: screenshots,
                                                             analysis: analysis,
                                                             suggestionsEnabled: purchases.isPro && settings.ocrEnabled)
            let matched = await SmartCollectionStore.evaluate(collection, facts: facts, context: ctx)
            guard !Task.isCancelled else { return }
            result = matched
            loading = false
            loadedChange = change
        }
        .sheet(item: $editing) { SmartCollectionEditor(collection: $0) }
        .fullScreenCover(item: $preview) { AssetPreviewView(request: $0) }
    }

    private func snapshot(name: String) async {
        do {
            if let id = try await albums.createAlbum(named: name), let album = albums.album(id: id) {
                try await albums.add(library.assets(for: result.matches), to: album)
                message = String(localized: "Created the Photos album “\(name)”. It won't update automatically.")
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

struct SmartCollectionEditor: View {
    @State var collection: SmartCollection

    @Environment(SmartCollectionStore.self) private var store
    @Environment(AlbumService.self) private var albums
    @Environment(ScreenshotStore.self) private var screenshots
    @Environment(\.dismiss) private var dismiss
    @State private var days = 30
    @State private var minutes = 2.0
    @State private var megabytes = 500.0
    @State private var rangeStart = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var rangeEnd = Date.now
    @State private var userAlbums: [AlbumInfo] = []
    @State private var labels: [String] = []

    var body: some View {
        let issues = SmartRuleEngine.validate(collection.rules, matchAll: collection.matchAll)
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $collection.name)
                    Picker("Match", selection: $collection.matchAll) {
                        Text("All rules").tag(true)
                        Text("Any rule").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Rules") {
                    ForEach(collection.rules, id: \.self) { rule in
                        Text(SmartRuleEngine.describe(rule))
                    }
                    .onDelete { collection.rules.remove(atOffsets: $0) }
                    ForEach(issues, id: \.self) { issue in
                        Label(issue.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.appFootnote)
                    }
                }
                Section("Add a rule") {
                    Menu("Media type") {
                        ForEach(MediaKind.allCases, id: \.self) { k in Button(String(localized: k.title)) { add(.mediaType(k)) } }
                    }
                    Menu("Review status") {
                        ForEach(ReviewStatus.allCases, id: \.self) { s in Button(String(localized: s.title)) { add(.reviewStatus(s)) } }
                    }
                    Menu("Favorite") {
                        Button("Is a favorite") { add(.favorite(true)) }
                        Button("Is not a favorite") { add(.favorite(false)) }
                    }
                    Stepper("Days: \(days)", value: $days, in: 1...3650)
                    HStack {
                        Button("Newer than \(days) days") { add(.newerThanDays(days)) }
                        Spacer()
                        Button("Older than \(days) days") { add(.olderThanDays(days)) }
                    }
                    .buttonStyle(.borderless)
                    DatePicker("From", selection: $rangeStart, displayedComponents: .date)
                    DatePicker("To", selection: $rangeEnd, displayedComponents: .date)
                    Button("Add date range") { add(.dateRange(start: rangeStart, end: rangeEnd)) }
                    Menu("In album") {
                        ForEach(userAlbums) { a in Button(a.title) { add(.inAlbum(id: a.id, title: a.title)) } }
                    }
                    Menu("Screenshot category") {
                        ForEach(ScreenshotCategory.allCases) { c in Button(String(localized: c.title)) { add(.screenshotCategory(c)) } }
                    }
                    if !labels.isEmpty {
                        Menu("Screenshot label") {
                            ForEach(labels, id: \.self) { l in Button(l) { add(.screenshotLabel(l)) } }
                        }
                    }
                    Button("Pinned screenshots") { add(.pinned) }
                    Stepper("Video minutes: \(Int(minutes))", value: $minutes, in: 1...120)
                    Button("Video longer than \(Int(minutes)) min") { add(.videoLongerThan(seconds: minutes * 60)) }
                    Stepper("Video MB: \(Int(megabytes))", value: $megabytes, in: 50...10_000, step: 50)
                    Button("Video larger than \(Int(megabytes)) MB") { add(.videoLargerThan(bytes: Int64(megabytes) * 1_000_000)) }
                }
            }
            .softAppBar()
            .task {
                userAlbums = await albums.userAlbums()
                labels = await screenshots.snapshot().labels
            }
            .navigationTitle(collection.name.isEmpty ? String(localized: "Smart Collection") : collection.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if collection.name.trimmedNonEmpty == nil { collection.name = String(localized: "Smart Collection") }
                        store.save(collection)
                        dismiss()
                    }
                    .disabled(!issues.isEmpty)
                }
            }
        }
    }

    private func add(_ rule: SmartRule) {
        if !collection.rules.contains(rule) { collection.rules.append(rule) }
    }
}
