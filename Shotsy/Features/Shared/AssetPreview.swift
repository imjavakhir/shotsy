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
    @State private var current: String
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
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $current) {
                ForEach(window, id: \.self) { id in
                    PreviewPage(assetID: id, onTap: toggleChrome) { playing in
                        if playing { playingID = id } else if playingID == id { playingID = nil }
                    }
                    .tag(id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
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
            .overlay(alignment: .bottom) {
                if !hidesChrome {
                    actionBar.transition(.opacity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar(hidesChrome ? .hidden : .visible, for: .navigationBar)
            .statusBarHidden(hidesChrome)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    if let asset = library.asset(for: current), let date = asset.creationDate {
                        VStack(spacing: 0) {
                            Text(date.formatted(date: .abbreviated, time: .omitted)).font(.appSubheadline.weight(.semibold))
                            Text(date.formatted(date: .omitted, time: .shortened)).font(.appCaption)
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
            .overlay(alignment: .top) {
                if let message {
                    Notice(kind: .info, text: LocalizedStringKey(message))
                        .padding()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onChange(of: current) {
                recenter()
                playingID = nil
            }
            .onAppear { recenter() }
            .sheet(isPresented: $showAlbumSheet) {
                AddToAlbumSheet(assetIDs: [current]) { title in flash(String(localized: "Added to \(title)")) }
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
            }
            .sheet(isPresented: $showLimit) {
                // Shown here because the app-level paywall sheet sits behind this full-screen preview.
                LimitSheet { dismiss() }
            }
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

    /// Our own action row: one clear icon per action, floating over the photo in Liquid Glass.
    private var actionBar: some View {
        let asset = library.asset(for: current)
        let favorite = asset.map(library.isFavorite) ?? false
        let marked = reviews.decision(for: current) == .marked
        return GlassEffectContainer(spacing: Space.s) {
          HStack {
            actionButton(favorite ? "Unfavorite" : "Favorite", favorite ? "heart.fill" : "heart",
                         tint: favorite ? Brand.blush : .white) {
                guard let asset else { return }
                Task { try? await library.setFavorite([asset], !favorite) }
            }
            Spacer()
            actionButton("Share", "square.and.arrow.up", busy: preparingShare) {
                guard let asset else { return }
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
            Spacer()
            actionButton("Add to Album", "rectangle.stack.badge.plus") { showAlbumSheet = true }
            Spacer()
            actionButton("Info", "info.circle") { showInfo = true }
            Spacer()
            actionButton(marked ? "Unmark" : "Mark for deletion", marked ? "trash.slash" : "trash",
                         tint: marked ? Color.appDanger : .white) {
                if marked {
                    reviews.unmark([current])
                    flash(String(localized: "Removed from the deletion queue"))
                } else {
                    do {
                        try reviews.decide(.marked, ids: [current])
                        flash(String(localized: "Marked for deletion. Nothing is deleted until you review."))
                    } catch {
                        showLimit = true
                    }
                }
            }
          }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.xs)
        .sensoryFeedback(.selection, trigger: favorite)
        .sensoryFeedback(.selection, trigger: marked)
    }

    private func actionButton(_ label: LocalizedStringKey, _ icon: String, tint: Color = .white, busy: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if busy { ProgressView().tint(.white) } else { Image(systemName: icon).font(.title3.weight(.semibold)) }
            }
            .foregroundStyle(tint)
            .frame(width: 52, height: 52)
            // A dark tint keeps the white symbols legible over bright photos.
            .glassEffect(.regular.tint(.black.opacity(0.35)).interactive(), in: .circle)
            .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(label)
    }

    private func flash(_ text: String) {
        withAnimation { message = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { message = nil }
        }
    }
}

private struct PreviewPage: View {
    let assetID: String
    /// Toggles the preview's chrome (single tap on a photo).
    let onTap: () -> Void
    /// A video page started or stopped playing.
    let onPlaying: (Bool) -> Void
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        if let asset = library.asset(for: assetID) {
            switch asset.mediaType {
            case .video: VideoPage(asset: asset, onPlaying: onPlaying)
            default:
                if asset.isLivePhoto { LivePhotoPage(asset: asset, onTap: onTap) } else { PhotoPage(asset: asset, onTap: onTap) }
            }
        } else {
            ContentUnavailableView("Not available", systemImage: "photo.badge.exclamationmark",
                                   description: Text("This item was deleted or Shotsy can no longer access it."))
                .foregroundStyle(.white)
        }
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
        scroll.addGestureRecognizer(tap)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap(_:)))
        single.require(toFail: tap)
        scroll.addGestureRecognizer(single)
        context.coordinator.imageView = view
        context.coordinator.onTap = onTap
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        var onTap: (() -> Void)?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let scroll = g.view as? UIScrollView else { return }
            scroll.setZoomScale(scroll.zoomScale > 1 ? 1 : 2.5, animated: true)
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
                LivePhotoView(livePhoto: livePhoto).onTapGesture(perform: onTap)
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

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        view.livePhoto = livePhoto
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
