import Photos
import SwiftUI

enum AlbumsRoute: Hashable {
    case album(String)
    case collection(UUID)
}

struct AlbumsTab: View {
    @Environment(Router.self) private var router
    @Environment(AlbumService.self) private var albums
    @Environment(PhotoLibrary.self) private var library
    @Environment(SmartCollectionStore.self) private var collections
    @Environment(PurchaseStore.self) private var purchases
    @State private var userAlbums: [AlbumInfo] = []
    @State private var smartAlbums: [AlbumInfo] = []
    @State private var creating = false
    @State private var newName = ""
    @State private var editingCollection: SmartCollection?
    @State private var error: String?
    @State private var loadedChange: Int?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Space.m)]

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.albumsPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if !library.access.canRead {
                        AccessBanner()
                    } else {
                        if let error { Notice(kind: .error, text: LocalizedStringKey(error)) }
                        HStack {
                            SectionHeader(title: "My Albums")
                            Button("New Album", systemImage: "plus") { creating = true }
                                .labelStyle(.iconOnly)
                                .frame(minWidth: Space.minTap, minHeight: Space.minTap)
                        }
                        let mine = userAlbums.filter { $0.kind == .user }
                        if mine.isEmpty {
                            Text("No albums yet. Create one, or add photos from Library.")
                                .font(.appCallout).foregroundStyle(Color.appSecondaryText)
                        }
                        LazyVGrid(columns: columns, spacing: Space.m) {
                            ForEach(mine) { album in
                                NavigationLink(value: AlbumsRoute.album(album.id)) { AlbumCard(album: album) }
                                    .buttonStyle(.plain)
                            }
                        }

                        smartCollectionsSection

                        let other = userAlbums.filter { $0.kind != .user } + smartAlbums
                        if !other.isEmpty {
                            SectionHeader(title: "In Photos", detail: "Read-only here")
                            LazyVGrid(columns: columns, spacing: Space.m) {
                                ForEach(other) { album in
                                    NavigationLink(value: AlbumsRoute.album(album.id)) { AlbumCard(album: album) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.page)
                .padding(.bottom, Space.xxl)
            }
            .softAppBar()
            .pageBackground()
            .navigationTitle("Albums")
            .toolbar { SettingsToolbarButton { router.sheet = .settings } }
            .navigationDestination(for: AlbumsRoute.self) { route in
                switch route {
                case .album(let id): AlbumDetailView(albumID: id)
                case .collection(let id): SmartCollectionDetailView(collectionID: id)
                }
            }
            .task(id: library.changeCount) { await reload() }
            .alert("New Album", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Create") {
                    Task {
                        do { _ = try await albums.createAlbum(named: newName.trimmedNonEmpty ?? String(localized: "New Album")) }
                        catch { self.error = error.localizedDescription }
                        newName = ""
                        await reload()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $editingCollection) { SmartCollectionEditor(collection: $0) }
        }
    }

    private var smartCollectionsSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                SectionHeader(title: "Smart Collections")
                Button("New Smart Collection", systemImage: "plus") {
                    if collections.canCreate(isPro: purchases.isPro) {
                        editingCollection = SmartCollection(id: UUID(), name: "", matchAll: true, rules: [])
                    } else {
                        router.showPaywall(.smartCollections)
                    }
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: Space.minTap, minHeight: Space.minTap)
            }
            Text("Shotsy's saved filters. They update on their own and aren't Photos albums.")
                .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
            if collections.collections.isEmpty {
                ForEach(SmartCollectionStore.examples.prefix(2)) { example in
                    Button {
                        if collections.canCreate(isPro: purchases.isPro) {
                            editingCollection = SmartCollection(id: UUID(), name: example.name, matchAll: example.matchAll, rules: example.rules)
                        } else { router.showPaywall(.smartCollections) }
                    } label: {
                        Label("Try “\(example.name)”", systemImage: "wand.and.stars")
                            .font(.appSubheadline).frame(minHeight: Space.minTap)
                    }
                }
            }
            ForEach(collections.collections) { c in
                NavigationLink(value: AlbumsRoute.collection(c.id)) {
                    HStack {
                        Image(systemName: "sparkles.rectangle.stack").foregroundStyle(Color.appAccent)
                        VStack(alignment: .leading) {
                            Text(c.name).font(.appHeadline).foregroundStyle(Color.appText)
                            Text(c.matchAll ? "Matches all rules" : "Matches any rule")
                                .font(.appCaption).foregroundStyle(Color.appSecondaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.appSecondaryText)
                    }
                    .card(padding: Space.s)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func reload() async {
        guard await BackgroundFetch.settle(changeCount: library.changeCount, loadedChangeCount: loadedChange) else { return }
        let change = library.changeCount
        async let mine = albums.userAlbums()
        async let smart = albums.smartAlbums()
        let (loadedMine, loadedSmart) = await (mine, smart)
        guard !Task.isCancelled else { return }
        userAlbums = loadedMine
        smartAlbums = loadedSmart
        loadedChange = change
    }
}

private struct AlbumCard: View {
    let album: AlbumInfo
    @Environment(AlbumService.self) private var albums

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Group {
                if let cover = albums.cover(for: album) {
                    SquareThumbnail(asset: cover, targetSide: 200)
                } else {
                    Rectangle().fill(Color.appChip)
                        .overlay(Image(systemName: "photo.on.rectangle").foregroundStyle(Color.appSecondaryText))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            HStack(spacing: 4) {
                Text(album.title).font(.appSubheadline.weight(.semibold)).foregroundStyle(Color.appText).lineLimit(1)
                if album.kind == .shared { Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(Color.appSecondaryText) }
            }
            Text("\(album.count)").font(.appCaption).foregroundStyle(Color.appSecondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Album grid with only the actions Photos supports for this album.
struct AlbumDetailView: View {
    let albumID: String

    @Environment(AlbumService.self) private var albums
    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var reviews
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var album: AlbumInfo?
    @State private var ids: [String] = []
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var renaming = false
    @State private var newName = ""
    @State private var adding = false
    @State private var confirmDeleteAlbum = false
    @State private var confirmDeletePhotos = false
    @State private var message: String?
    @State private var preview: PreviewRequest?
    @State private var loadedChange: Int?

    var body: some View {
        VStack(spacing: 0) {
            if let message { Notice(kind: .info, text: LocalizedStringKey(message)).padding(.horizontal, Space.page) }
            if album?.isReadOnly == true {
                Text("Photos doesn't allow editing this album. You can still view, share, or mark items.")
                    .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                    .padding(.horizontal, Space.page).padding(.vertical, Space.xs)
            }
            if ids.isEmpty {
                MascotMessage(animated: .idle, title: "Empty album", message: album?.canAdd == true ? "Add photos from your library." : "Nothing here yet.")
                Spacer()
            } else {
                AssetIDGrid(ids: ids, selection: $selection, selectionMode: selecting) { preview = PreviewRequest(ids: ids, start: $0) }
            }
        }
        .pageBackground()
        .navigationTitle(album?.title ?? "")
        .toolbar { toolbar }
        .task(id: library.changeCount) { await load() }
        .alert("Rename Album", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { Task { await run { try await albums.rename(album!, to: newName) } } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this album?", isPresented: $confirmDeleteAlbum, titleVisibility: .visible) {
            Button("Delete Album", role: .destructive) {
                Task { await run { try await albums.deleteAlbum(album!) }; dismiss() }
            }
        } message: {
            Text("Only the album is deleted. The photos stay in your library.")
        }
        .confirmationDialog("Delete \(selection.count) items from Photos?", isPresented: $confirmDeletePhotos, titleVisibility: .visible) {
            Button("Delete from Photos", role: .destructive) { Task { await deleteFromPhotos() } }
        } message: {
            Text("This deletes the items from your whole library, not just this album. They go to Recently Deleted for about 30 days.")
        }
        .sheet(isPresented: $adding) {
            AssetPickerSheet(title: String(localized: "Add Photos")) { picked in
                Task { await run { try await albums.add(library.assets(for: picked), to: album!) } }
            }
        }
        .fullScreenCover(item: $preview) { AssetPreviewView(request: $0) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(selecting ? "Done Selecting" : "Select", systemImage: "checkmark.circle") { selecting.toggle(); selection.removeAll() }
                if album?.canAdd == true { Button("Add Photos", systemImage: "plus") { adding = true } }
                if album?.canRename == true { Button("Rename", systemImage: "pencil") { newName = album?.title ?? ""; renaming = true } }
                Button("Review one by one", systemImage: "hand.draw") {
                    model.startSession(kind: .album, title: album?.title ?? "", assetIDs: ids)
                }
                if album?.canDelete == true {
                    Button("Delete Album", systemImage: "trash", role: .destructive) { confirmDeleteAlbum = true }
                }
            } label: { Label("Actions", systemImage: "ellipsis.circle") }
        }
        if selecting {
            ToolbarItemGroup(placement: .bottomBar) {
                ShareAssetsButton(ids: Array(selection))
                Spacer()
                if album?.canRemove == true {
                    Button("Remove from album") {
                        Task { await run { try await albums.remove(library.assets(for: Array(selection)), from: album!) }; selection.removeAll() }
                    }
                    .disabled(selection.isEmpty)
                    Spacer()
                }
                Menu("Delete") {
                    Button("Mark for deletion", systemImage: "trash") {
                        do { try reviews.decide(.marked, ids: Array(selection)); selection.removeAll() }
                        catch { router.showPaywall(.dailyLimit) }
                    }
                    Button("Delete from Photos…", systemImage: "trash.fill", role: .destructive) { confirmDeletePhotos = true }
                }
                .disabled(selection.isEmpty)
            }
        }
    }

    private func load() async {
        guard await BackgroundFetch.settle(changeCount: library.changeCount, loadedChangeCount: loadedChange) else { return }
        let change = library.changeCount
        let albumID = albumID
        let (info, list) = await BackgroundFetch.run { () -> (AlbumInfo?, [String]) in
            guard let info = AlbumService.album(id: albumID) else { return (nil, []) }
            return (info, BackgroundFetch.identifiers(in: AlbumService.assets(in: info)))
        }
        guard !Task.isCancelled else { return }
        album = info
        ids = list
        if info != nil { selection.formIntersection(Set(list)) }
        loadedChange = change
    }

    private func run(_ work: () async throws -> Void) async {
        do {
            try await work()
            await load()
        } catch {
            message = error.localizedDescription
        }
    }

    private func deleteFromPhotos() async {
        let (outcome, plan) = await model.deletion.delete(ids: Array(selection))
        switch outcome {
        case .deleted(let count, _):
            reviews.forget(Set(plan.deletable))
            message = String(localized: "Deleted \(count) items. They're in Recently Deleted in Photos.")
            selection.removeAll()
        case .cancelled:
            message = String(localized: "Nothing was deleted.")
        case .failed(let text):
            message = text
        }
        await load()
    }
}
