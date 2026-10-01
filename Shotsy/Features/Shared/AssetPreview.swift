import AVKit
import Photos
import PhotosUI
import SwiftUI

/// Full-screen preview with paging, zoom, Live Photo and video playback, and item actions. Like Photos, media
/// fills the screen edge to edge and the chrome (title, Liquid Glass actions) floats over it; a tap toggles it.
struct AssetPreviewView: View {
    let request: PreviewRequest

    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var reviews
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// The app's appearance, restored for sheets: the preview itself is always dark.
    @Environment(\.colorScheme) private var outerScheme
    @State private var current: String
    /// The page on screen, readable at tap time by toolbar actions (see `PreviewSelection`).
    @State private var selection: PreviewSelection
    @State private var window: [String] = []
    @State private var showAlbumSheet = false
    @State private var message: String?
    @State private var shareURLs: [URL] = []
    @State private var showShare = false
    @State private var preparingShare = false
    @State private var showLimit = false
    @State private var showInfo = false
    /// Set by the info sheet; the limit sheet opens once the info sheet is gone.
    @State private var limitAfterInfo = false
    /// Hidden by a tap on the photo.
    @State private var chromeHidden = false
    /// The video page that is playing, if any. Its own controls take over, so ours step aside.
    @State private var playingID: String?

    init(request: PreviewRequest) {
        self.request = request
        _current = State(initialValue: request.start)
        _selection = State(initialValue: PreviewSelection(id: request.start))
    }

    var body: some View {
        // System navigation bar and bottom toolbar with transparent backgrounds: UIKit owns the controls, so
        // every tap lands on the first try, while the pager ignores the safe area and fills the whole screen.
        NavigationStack {
            // A paging ScrollView rather than a page-style TabView: inside a NavigationStack the TabView
            // offsets its pages below the top edge even when ignoring the safe area.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(window, id: \.self) { id in
                        PreviewPage(assetID: id, onTap: toggleChrome) { playing in
                            if playing { playingID = id } else if playingID == id { playingID = nil }
                        }
                        .containerRelativeFrame([.horizontal, .vertical])
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: Binding(get: { current }, set: { if let id = $0 { current = id } }))
            .ignoresSafeArea()
            .background(Color.black.ignoresSafeArea())
            .overlay(alignment: .top) {
                // Subtle scrim so the white date title stays legible over bright photos.
                if !hidesChrome {
                    LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 140)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .principal) { PreviewTitle(assetID: current) }
                bottomBar
            }
            // Transparent bars over the photo; dark styling keeps the glass controls legible.
            .toolbarBackground(.hidden, for: .navigationBar, .bottomBar)
            .toolbar(hidesChrome ? .hidden : .visible, for: .navigationBar, .bottomBar)
            .statusBarHidden(hidesChrome)
            .overlay(alignment: .top) {
                if let message {
                    Notice(kind: .info, text: LocalizedStringKey(message))
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onChange(of: current) {
                selection.id = current
                recenter()
                playingID = nil
            }
            .onAppear { recenter() }
            .sheet(isPresented: $showAlbumSheet) {
                AddToAlbumSheet(assetIDs: [current]) { title in flash(String(localized: "Added to \(title)")) }
                    .environment(\.colorScheme, outerScheme)
                    .tint(Color.appAccent)
            }
            .sheet(isPresented: $showShare) {
                ActivityView(items: shareURLs).presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showInfo, onDismiss: {
                if limitAfterInfo {
                    limitAfterInfo = false
                    showLimit = true
                }
            }) {
                AssetInfoSheet(assetID: current) {
                    limitAfterInfo = true
                    showInfo = false
                }
                .environment(\.colorScheme, outerScheme)
                .tint(Color.appAccent)
            }
            .sheet(isPresented: $showLimit) {
                // Shown here because the app-level paywall sheet sits behind this full-screen preview.
                LimitSheet { dismiss() }
                    .environment(\.colorScheme, outerScheme)
                    .tint(Color.appAccent)
            }
        }
        // No app tint on the bars: Liquid Glass picks a legible symbol color over the photo, like Photos.
        .tint(nil)
    }

    /// The action row, as system bottom-bar items (each its own glass control).
    @ToolbarContentBuilder private var bottomBar: some ToolbarContent {
            ToolbarItem(placement: .bottomBar) { FavoriteToolbarButton(assetID: current, selection: selection) }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("Share", systemImage: "square.and.arrow.up") {
                    if let asset = library.asset(for: selection.id) { share(asset) }
                }
                .disabled(preparingShare)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("Add to Album", systemImage: "rectangle.stack.badge.plus") { showAlbumSheet = true }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("Info", systemImage: "info.circle") { showInfo = true }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                MarkToolbarButton(assetID: current, selection: selection, onLimit: { showLimit = true }, flash: flash)
            }
    }

    /// Chrome steps aside when the user hides it or the current video is playing. With VoiceOver on it stays,
    /// so the actions are always reachable.
    private var hidesChrome: Bool {
        !voiceOver && (chromeHidden || playingID == current)
    }

    private func toggleChrome() {
        guard !voiceOver else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { chromeHidden.toggle() }
    }

    /// Keeps a bounded window of pages around the current item, so huge libraries stay light.
    private func recenter() {
        guard let index = request.ids.firstIndex(of: current) else { window = [current]; return }
        let lower = max(0, index - 60), upper = min(request.ids.count, index + 61)
        let next = Array(request.ids[lower..<upper])
        if next != window { window = next }
    }

    private func share(_ asset: PHAsset) {
        Task {
            preparingShare = true
            shareURLs = await ShareExporter.files(for: [asset])
            preparingShare = false
            if shareURLs.isEmpty {
                flash(String(localized: "Couldn't prepare this item. It may be in iCloud while you're offline."))
            } else {
                showShare = true
            }
        }
    }

    private func flash(_ text: String) {
        withAnimation { message = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { message = nil }
        }
    }
}

/// The item on screen, as a reference: toolbar actions read it when tapped rather than capturing a value.
private final class PreviewSelection {
    var id: String
    init(id: String) { self.id = id }
}

/// Date and time of the current item. Separate so library changes re-render only this, not the pager.
private struct PreviewTitle: View {
    let assetID: String
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        if let date = library.asset(for: assetID)?.creationDate {
            VStack(spacing: 0) {
                Text(date.formatted(date: .abbreviated, time: .omitted)).font(.appSubheadline.weight(.semibold))
                Text(date.formatted(date: .omitted, time: .shortened)).font(.appCaption)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 3)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Favorite toggle. Observes favorites itself, so toggling re-renders only this button.
private struct FavoriteToolbarButton: View {
    let assetID: String
    let selection: PreviewSelection
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        let favorite = library.asset(for: assetID).map(library.isFavorite) ?? false
        Button(favorite ? "Unfavorite" : "Favorite", systemImage: favorite ? "heart.fill" : "heart") {
            // Read the item and its state now: the bar item's action may predate the last render.
            guard let asset = library.asset(for: selection.id) else { return }
            let now = library.isFavorite(asset)
            Task { try? await library.setFavorite([asset], !now) }
        }
        .tint(favorite ? Brand.blush : nil)
        .sensoryFeedback(.selection, trigger: favorite)
    }
}

/// Mark for deletion / unmark. Observes review decisions itself.
private struct MarkToolbarButton: View {
    let assetID: String
    let selection: PreviewSelection
    let onLimit: () -> Void
    let flash: (String) -> Void
    @Environment(ReviewStore.self) private var reviews

    var body: some View {
        let marked = reviews.decision(for: assetID) == .marked
        Button(marked ? "Unmark" : "Mark for deletion", systemImage: marked ? "trash.slash" : "trash") {
            // Read the item and its state now: the bar item's action may predate the last render.
            let id = selection.id
            if reviews.decision(for: id) == .marked {
                reviews.unmark([id])
                flash(String(localized: "Removed from the deletion queue"))
            } else {
                do {
                    try reviews.decide(.marked, ids: [id])
                    flash(String(localized: "Marked for deletion. Nothing is deleted until you review."))
                } catch {
                    onLimit()
                }
            }
        }
        .tint(marked ? Color.appDanger : nil)
        .sensoryFeedback(.selection, trigger: marked)
    }
}

private struct PreviewPage: View {
    let assetID: String
    /// Toggles the preview's chrome (single tap on a photo).
    let onTap: () -> Void
    /// A video page started or stopped playing.
    let onPlaying: (Bool) -> Void
    @Environment(PhotoLibrary.self) private var library
    /// Resolved once per page (and again only if it disappears from the library), not on every render.
    @State private var asset: PHAsset?
    @State private var resolved = false

    var body: some View {
        Group {
            if let asset {
                switch asset.mediaType {
                case .video: VideoPage(asset: asset, onPlaying: onPlaying)
                default:
                    if asset.isLivePhoto { LivePhotoPage(asset: asset, onTap: onTap) } else { PhotoPage(asset: asset, onTap: onTap) }
                }
            } else if resolved {
                ContentUnavailableView("Not available", systemImage: "photo.badge.exclamationmark",
                                       description: Text("This item was deleted or Shotsy can no longer access it."))
                    .foregroundStyle(.white)
            } else {
                Color.clear
            }
        }
        .contentShape(Rectangle())
        .onAppear(perform: resolve)
        .onChange(of: library.changeCount) {
            // Only the item's existence matters here; favorites and decisions are shown by the action bar.
            let exists = library.asset(for: assetID) != nil
            if exists != (asset != nil) { resolve() }
        }
    }

    private func resolve() {
        asset = library.asset(for: assetID)
        resolved = true
    }
}

/// Loads a screen-sized image, downloading from iCloud with visible progress when needed.
private struct PhotoPage: View {
    let asset: PHAsset
    let onTap: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var progress: Double?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image, onTap: onTap)
            }
            if let progress, progress < 1 {
                DownloadBadge(progress: progress)
            }
            if failed {
                Notice(kind: .warning, text: "Couldn't load this photo. It may be in iCloud while you're offline.")
                    .padding()
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        // Before the zoomable image exists, a plain tap still toggles the chrome.
        .onTapGesture { if image == nil { onTap() } }
        .task(id: asset.localIdentifier) { await load() }
    }

    private func load() async {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value, _, _, _ in
            Task { @MainActor in progress = value }
        }
        let side = 1000 * displayScale
        for await update in ImageStream.images(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit,
                                               options: options, manager: PHImageManager.default()) {
            if let img = update.image { image = img }
            if !update.isDegraded && update.image == nil { failed = true }
        }
        progress = nil
    }
}

private struct DownloadBadge: View {
    let progress: Double
    var body: some View {
        VStack(spacing: 6) {
            ProgressView(value: progress).frame(width: 120).tint(.white)
            Text("Downloading from iCloud").font(.appCaption).foregroundStyle(.white)
        }
        .padding(12)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    /// Single tap (after a double tap is ruled out).
    var onTap: (() -> Void)?

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 5
        scroll.minimumZoomScale = 1
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.bouncesZoom = true
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isAccessibilityElement = true
        scroll.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        tap.delegate = context.coordinator
        scroll.addGestureRecognizer(tap)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap(_:)))
        single.require(toFail: tap)
        single.delegate = context.coordinator
        scroll.addGestureRecognizer(single)
        context.coordinator.imageView = view
        context.coordinator.onTap = onTap
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        if context.coordinator.imageView?.image !== image { context.coordinator.imageView?.image = image }
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        weak var imageView: UIImageView?
        var onTap: (() -> Void)?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        /// Only touches that land on the photo itself. Taps on the floating buttons (SwiftUI views layered
        /// above) must not also zoom the photo or toggle the chrome.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            PreviewTouch.isOn(g.view, touch)
        }
        /// Like Photos: zoom in on the spot that was tapped, or back out to fit.
        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let scroll = g.view as? UIScrollView, let imageView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
                return
            }
            let scale: CGFloat = 2.5
            let point = g.location(in: imageView)
            let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                   width: size.width, height: size.height), animated: true)
        }
        @objc func singleTap(_ g: UITapGestureRecognizer) { onTap?() }
    }
}

private struct LivePhotoPage: View {
    let asset: PHAsset
    let onTap: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var livePhoto: PHLivePhoto?

    var body: some View {
        ZStack {
            if let livePhoto {
                // Touch and hold plays; a tap toggles the chrome.
                LivePhotoView(livePhoto: livePhoto, onTap: onTap)
            } else {
                PhotoPage(asset: asset, onTap: onTap)
            }
        }
        .ignoresSafeArea()
        .task(id: asset.localIdentifier) {
            let options = PHLivePhotoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            let a = asset
            // Screen-sized like PhotoPage: neighboring pages stay alive, so full-size decodes would add up.
            let side = 1000 * displayScale
            livePhoto = await withCheckedContinuation { c in
                var resumed = false
                PHImageManager.default().requestLivePhoto(for: a, targetSize: CGSize(width: side, height: side),
                                                          contentMode: .aspectFit, options: options) { photo, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    guard !degraded, !resumed else { return }
                    resumed = true
                    c.resume(returning: photo)
                }
            }
        }
    }
}

/// Native Live Photo view: touch and hold to play.
struct LivePhotoView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    /// Single tap. A UIKit recognizer, so it doesn't compete with the view's own press-and-hold playback.
    var onTap: (() -> Void)?

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto { view.livePhoto = livePhoto }
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (() -> Void)?
        @objc func tap() { onTap?() }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            PreviewTouch.isOn(g.view, touch)
        }
    }
}

/// Whether a touch really landed on a page's UIKit view rather than on SwiftUI controls drawn above it.
private enum PreviewTouch {
    static func isOn(_ view: UIView?, _ touch: UITouch) -> Bool {
        guard let view, let hit = touch.view else { return false }
        return hit === view || hit.isDescendant(of: view)
    }
}

private struct VideoPage: View {
    let asset: PHAsset
    let onPlaying: (Bool) -> Void
    @State private var player: AVPlayer?
    @State private var failed = false

    /// Room above the bottom edge for our floating action row, so the player's own controls sit above it
    /// while paused. The picture itself still fills the screen.
    private static let controlsClearance: CGFloat = 76

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .safeAreaPadding(.bottom, Self.controlsClearance)
                    .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                        onPlaying(status != .paused)
                    }
            } else if failed {
                Notice(kind: .warning, text: "Couldn't load this video. It may be in iCloud while you're offline.").padding()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: asset.localIdentifier) {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            let a = asset
            let item: AVPlayerItem? = await withCheckedContinuation { c in
                PHImageManager.default().requestPlayerItem(forVideo: a, options: options) { item, _ in
                    c.resume(returning: item)
                }
            }
            if let item { player = AVPlayer(playerItem: item) } else { failed = true }
        }
        .ignoresSafeArea()
        .onDisappear {
            player?.pause()
            onPlaying(false)
        }
    }
}
