import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Adds existing library photos to an album (same assets, no copies). Only editable albums are offered.
/// In choose mode it only picks an album (or creates one) and adds nothing.
struct AddToAlbumSheet: View {
    let assetIDs: [String]
    var onDone: ((String) -> Void)?
    /// Called with the album the items went into, or, in choose mode, the album picked.
    var onAlbum: ((AlbumInfo) -> Void)? = nil
    var chooseOnly = false
    /// Shown with a checkmark in choose mode.
    var selectedID: String? = nil

    @Environment(AlbumService.self) private var albums
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var list: [AlbumInfo] = []
    @State private var newName = ""
    @State private var showNew = false
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Notice(kind: .error, text: LocalizedStringKey(error))
                }
                Section {
                    Button {
                        showNew = true
                    } label: {
                        Label("New Album", systemImage: "plus.rectangle.on.rectangle")
                    }
                }
                Section("Albums") {
                    ForEach(list.filter(\.canAdd)) { album in
                        Button {
                            Task { await add(to: album) }
                        } label: {
                            HStack {
                                Text(album.title).foregroundStyle(Color.appText)
                                Spacer()
                                if chooseOnly && album.id == selectedID {
                                    Image(systemName: "checkmark").foregroundStyle(Color.appAccent)
                                        .accessibilityLabel("Selected")
                                }
                                Text(album.count, format: .number).foregroundStyle(Color.appSecondaryText)
                            }
                        }
                        .disabled(working)
                    }
                }
            }
            .softAppBar()
            .navigationTitle(chooseOnly ? LocalizedStringKey("Choose Album") : LocalizedStringKey("Add to Album"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("New Album", isPresented: $showNew) {
                TextField("Name", text: $newName)
                Button("Create") { Task { await createAndAdd() } }
                Button("Cancel", role: .cancel) {}
            }
            .task { list = await albums.userAlbums() }
        }
        .presentationDetents([.medium, .large])
    }

    private func add(to album: AlbumInfo) async {
        if chooseOnly {
            onAlbum?(album)
            dismiss()
            return
        }
        working = true
        defer { working = false }
        do {
            try await albums.add(library.assets(for: assetIDs), to: album)
            onDone?(album.title)
            onAlbum?(album)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createAndAdd() async {
        guard let name = newName.trimmedNonEmpty else { return }
        do {
            if let id = try await albums.createAlbum(named: name), let album = albums.album(id: id) {
                await add(to: album)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Exports originals to temporary files for the share sheet (explicit user action; may download from iCloud).
enum ShareExporter {
    static func files(for assets: [PHAsset]) async -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for asset in assets {
            let resources = PHAssetResource.assetResources(for: asset)
            let primary = resources.first { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }
                ?? resources.first { $0.type == .photo || $0.type == .video }
            guard let resource = primary else { continue }
            let url = dir.appendingPathComponent(resource.originalFilename)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            nonisolated(unsafe) let r = resource
            let ok: Bool = await withCheckedContinuation { c in
                PHAssetResourceManager.default().writeData(for: r, toFile: url, options: options) { error in
                    c.resume(returning: error == nil)
                }
            }
            if ok { urls.append(url) }
        }
        return urls
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Share button that prepares files first, then shows the system share sheet.
struct ShareAssetsButton: View {
    let ids: [String]
    @Environment(PhotoLibrary.self) private var library
    @State private var urls: [URL] = []
    @State private var preparing = false
    @State private var showSheet = false

    var body: some View {
        Button {
            Task {
                preparing = true
                urls = await ShareExporter.files(for: library.assets(for: ids))
                preparing = false
                showSheet = !urls.isEmpty
            }
        } label: {
            // Keep the icon (a spinner inside a toolbar renders as an empty pill); dim while preparing.
            Label("Share", systemImage: "square.and.arrow.up")
                .opacity(preparing ? 0.4 : 1)
        }
        .disabled(ids.isEmpty || preparing)
        .sheet(isPresented: $showSheet) {
            ActivityView(items: urls).presentationDetents([.medium, .large])
        }
    }
}

enum LimitedLibrary {
    /// Lets people with limited access change which photos Shotsy can see.
    static func presentPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }
}

/// Face crop from a photo, using a normalized Vision box (origin bottom-left).
struct FaceCropView: View {
    let assetID: String
    let box: CGRect?

    @Environment(PhotoLibrary.self) private var library
    @State private var image: UIImage?

    var body: some View {
        Circle()
            .fill(Color.appChip)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle").foregroundStyle(Color.appSecondaryText)
                }
            }
            .clipShape(Circle())
            .task(id: assetID) { await load() }
            .accessibilityHidden(true)
    }

    private func load() async {
        guard let asset = library.asset(for: assetID) else { return }
        let stream = ImageStream.images(for: asset, targetSize: CGSize(width: 600, height: 600), contentMode: .aspectFit,
                                        options: ThumbnailCache.gridOptions(), manager: ThumbnailCache.shared.manager)
        var last: UIImage?
        for await update in stream { if let i = update.image { last = i } }
        guard let full = last?.cgImage else { return }
        guard let box else { image = last; return }
        if let crop = FaceCrop.crop(full, box: box, side: 200, margin: 0.35) {
            image = UIImage(cgImage: crop)
        }
    }
}
