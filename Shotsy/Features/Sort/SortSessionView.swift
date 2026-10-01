import AVKit
import Photos
import SwiftUI

/// The central interaction: one large card, swipe right to keep, left to mark for deletion, up to file it into
/// an album (and keep it). Marking only changes Shotsy's pending queue; Photos is untouched until confirmed deletion.
struct SortSessionView: View {
    let sessionID: UUID

    @Environment(ReviewStore.self) private var reviews
    @Environment(PhotoLibrary.self) private var library
    @Environment(Router.self) private var router
    @Environment(SettingsStore.self) private var settings
    @Environment(PurchaseStore.self) private var purchases
    @Environment(AlbumService.self) private var albums
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The card's drag offset and fly state. Only `CardDeck` reads the offset, so a drag frame invalidates the
    /// deck, not this view's toolbar, buttons and sheets.
    @State private var motion = DeckMotion()
    @State private var limitReached = false
    @State private var albumSheet: AlbumSheet?
    /// Where swipe up files photos. Remembered across sessions while the album exists.
    @State private var quickAlbum: AlbumInfo?
    @State private var preview: PreviewRequest?
    @State private var feedback = 0
    @State private var toast: String?
    // Session, state and the next cards are cached and refreshed only when the session or library
    // changes. The drag updates `motion.offset` every frame; it must not invalidate this body.
    @State private var record: SessionRecord?
    @State private var state: SessionState?
    /// The current card plus the next two, loaded behind it so they're ready when it flies off.
    @State private var deck: [PHAsset] = []
    @State private var loaded = false

    private let threshold: CGFloat = 110
    private static let quickAlbumKey = "sortQuickAlbumID"

    private enum AlbumSheet: Identifiable {
        /// "Add to Album" button: adds only, no decision.
        case add(String)
        /// First swipe up with no album chosen: adds, remembers the album, then keeps.
        case swipeUp(String)
        /// Changes the swipe-up album without adding anything.
        case choose

        var id: String {
            switch self {
            case .add(let id): "add-\(id)"
            case .swipeUp(let id): "up-\(id)"
            case .choose: "choose"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView()
                } else if let record, let state {
                    if state.isFinished {
                        SessionSummary(state: state, title: record.displayTitle) { dismiss() }
                    } else {
                        sorting(record: record, state: state)
                    }
                } else {
                    ContentUnavailableView("Session not found", systemImage: "questionmark.square.dashed")
                }
            }
            .pageBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    if let record, let state {
                        VStack(spacing: 0) {
                            Text(record.displayTitle).font(.appSubheadline.weight(.semibold))
                            Text("\(min(state.position + 1, state.assetIDs.count)) of \(state.assetIDs.count)")
                                .font(.appCaption).foregroundStyle(Color.appSecondaryText)
                                .monospacedDigit()
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if reviews.pendingCount > 0 {
                        Button { router.sheet = .reviewDeletions; dismiss() } label: {
                            Label("\(reviews.pendingCount) marked", systemImage: "trash")
                                .labelStyle(.titleAndIcon)
                        }
                        .accessibilityHint("Opens the deletion review")
                    }
                }
            }
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: feedback) { _, _ in settings.hapticsEnabled }
            .sheet(isPresented: $limitReached) { LimitSheet { dismiss() } }
            .sheet(item: $albumSheet) { sheet in
                switch sheet {
                case .add(let id):
                    AddToAlbumSheet(assetIDs: [id]) { title in showToast(String(localized: "Added to \(title)")) }
                case .swipeUp(let id):
                    AddToAlbumSheet(assetIDs: [id], onAlbum: { album in
                        rememberQuickAlbum(album)
                        showToast(String(localized: "Added to \(album.title)"))
                        if let record, state?.currentID == id { act(.keep, record, up: true) }
                    })
                case .choose:
                    AddToAlbumSheet(assetIDs: [], onAlbum: { album in rememberQuickAlbum(album) },
                                    chooseOnly: true, selectedID: quickAlbum?.id)
                }
            }
            .fullScreenCover(item: $preview) { AssetPreviewView(request: $0) }
        }
        .onAppear {
            refresh()
            loadQuickAlbum()
        }
        .onChange(of: reviews.revision) { refresh() }
        .onChange(of: library.changeCount) { refresh() }
    }

    private func refresh() {
        let r = reviews.session(id: sessionID)
        let s = r.map { reviews.state(of: $0) }
        record = r
        state = s
        if let s, !s.isFinished {
            deck = library.assets(for: Array(s.assetIDs[s.position..<min(s.position + 3, s.assetIDs.count)]))
        } else {
            deck = []
        }
        loaded = true
    }

    @ViewBuilder
    private func sorting(record: SessionRecord, state: SessionState) -> some View {
        let asset = deck.first.flatMap { $0.localIdentifier == state.currentID ? $0 : nil }
        VStack(spacing: Space.s) {
            ProgressView(value: Double(state.position), total: Double(max(1, state.assetIDs.count)))
                .tint(Color.appAccentFill)
                .padding(.horizontal, Space.page)
                .accessibilityHidden(true)

            GeometryReader { geo in
                ZStack {
                    if asset != nil {
                        CardDeck(deck: deck, size: geo.size, motion: motion, threshold: threshold,
                                 zoom: { id in preview = PreviewRequest(ids: [id], start: id) },
                                 act: { act($0, record) },
                                 fileIntoAlbum: { fileIntoAlbum(record) },
                                 springBack: springBack)
                    } else if let id = state.currentID {
                        // Asset vanished (deleted elsewhere or access changed): drop it from the session.
                        ProgressView().task { reviews.forget([id]) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, Space.page)

            if let toast {
                Text(toast).font(.appFootnote).foregroundStyle(Color.appSecondaryText).transition(.opacity)
            }

            HStack(spacing: Space.xl) {
                bigButton("Mark for deletion", "trash", .appDanger) { act(.mark, record) }
                bigButton("Keep", "checkmark", .appSuccess) { act(.keep, record) }
            }
            .disabled(motion.flying || asset == nil)

            HStack {
                smallButton("Undo", "arrow.uturn.backward", enabled: state.canUndo) {
                    withAnimation(.snappy) { reviews.undo(in: record) }
                    feedback += 1
                }
                smallButton("Skip", "forward", enabled: asset != nil) { act(.skip, record) }
                let favorite = asset.map(library.isFavorite) ?? false
                smallButton(favorite ? "Unfavorite" : "Favorite",
                            favorite ? "heart.fill" : "heart", enabled: asset != nil) {
                    guard let asset else { return }
                    Task { try? await library.setFavorite([asset], !favorite) }
                }
                smallButton("Add to Album", "rectangle.stack.badge.plus", enabled: asset != nil) {
                    if let id = state.currentID { albumSheet = .add(id) }
                }
            }
            .padding(.horizontal, Space.page)

            quickAlbumChip

            if let remaining = reviews.remainingToday, !purchases.isPro {
                Text("\(remaining) free reviews left today")
                    .font(.appCaption).foregroundStyle(Color.appSecondaryText)
            }
        }
        .padding(.bottom, Space.s)
    }

    /// Shows and changes where swipe up files photos.
    private var quickAlbumChip: some View {
        Button { albumSheet = .choose } label: {
            HStack(spacing: Space.xxs) {
                Image(systemName: "arrow.up")
                if let quickAlbum {
                    Text("Swipe up: \(quickAlbum.title)").lineLimit(1)
                } else {
                    Text("Swipe up to add to an album").lineLimit(1)
                }
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.appCaption)
            .foregroundStyle(Color.appAccent)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xxs)
            .background(Color.appChip, in: Capsule())
            .frame(minHeight: Space.minTap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Choose the album photos go to when you swipe up")
    }

    private func springBack() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { motion.offset = .zero }
    }

    private func canDecide(_ id: String) -> Bool {
        reviews.ledger.canDecide(id, day: ReviewStore.today, policy: reviews.policy, isPro: purchases.isPro)
    }

    /// Swipe up: adds the photo to the swipe-up album, then keeps it through the normal `act` path.
    /// With no album chosen yet, the picker adds it and remembers the choice. A failed add keeps nothing.
    private func fileIntoAlbum(_ record: SessionRecord) {
        guard !motion.flying, let id = state?.currentID else { return }
        guard canDecide(id) else {
            springBack()
            limitReached = true
            return
        }
        guard let chosen = quickAlbum else {
            springBack()
            albumSheet = .swipeUp(id)
            return
        }
        guard let album = albums.album(id: chosen.id), album.canAdd else {
            springBack()
            forgetQuickAlbum()
            showToast(String(localized: "That album is no longer available. Swipe up again to choose another."))
            return
        }
        motion.flying = true
        Task {
            do {
                try await albums.add(library.assets(for: [id]), to: album)
                quickAlbum = album
                motion.flying = false
                showToast(String(localized: "Added to \(album.title)"))
                act(.keep, record, up: true)
            } catch {
                motion.flying = false
                springBack()
                showToast(String(localized: "Couldn't add to \(album.title)."))
            }
        }
    }

    private func loadQuickAlbum() {
        guard quickAlbum == nil, let id = UserDefaults.standard.string(forKey: Self.quickAlbumKey) else { return }
        if let album = albums.album(id: id), album.canAdd {
            quickAlbum = album
        } else {
            forgetQuickAlbum()
        }
    }

    private func rememberQuickAlbum(_ album: AlbumInfo) {
        quickAlbum = album
        UserDefaults.standard.set(album.id, forKey: Self.quickAlbumKey)
    }

    private func forgetQuickAlbum() {
        quickAlbum = nil
        UserDefaults.standard.removeObject(forKey: Self.quickAlbumKey)
    }

    /// `up` flies the card upward (filed into an album) instead of sideways.
    private func act(_ outcome: SessionOutcome, _ record: SessionRecord, up: Bool = false) {
        guard !motion.flying else { return }
        if outcome != .skip, let id = state?.currentID, !canDecide(id) {
            springBack()
            limitReached = true
            return
        }
        motion.flying = true
        let direction: CGFloat = outcome == .keep ? 1 : outcome == .mark ? -1 : 0
        let finish = {
            do {
                try reviews.apply(outcome, in: record)
                // Promote the next card in this same update, so the flown-off card never snaps back.
                refresh()
                feedback += 1
            } catch ReviewError.dailyLimitReached {
                limitReached = true
            } catch {}
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { motion.offset = .zero }
            motion.flying = false
        }
        if reduceMotion || direction == 0 {
            finish()
        } else {
            // Short settle-out, ~200 ms.
            let offset = motion.offset
            withAnimation(.easeIn(duration: 0.18)) {
                motion.offset = up ? CGSize(width: offset.width, height: -1200)
                    : CGSize(width: direction * 600, height: offset.height)
            } completion: { finish() }
        }
    }

    private func bigButton(_ label: LocalizedStringKey, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Space.xxs) {
                Image(systemName: icon)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(color, in: Circle())
                Text(label).font(.appCaption).foregroundStyle(Color.appText)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func smallButton(_ label: LocalizedStringKey, _ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.body.weight(.semibold))
                Text(label).font(.appCaption).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(enabled ? Color.appAccent : Color.appSecondaryText.opacity(0.5))
            .frame(maxWidth: .infinity, minHeight: Space.minTap)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toast = nil }
        }
    }
}

/// Drag offset and fly state of the top card. A reference type so writing the offset every drag frame only
/// invalidates the views that read it (the top card's motion modifier), not the session screen.
@Observable
private final class DeckMotion {
    var offset: CGSize = .zero
    /// A card is flying off (or being filed into an album). Gestures and buttons wait.
    var flying = false
}

/// The current card plus the next two. Body re-runs when the deck or fly state changes, not per drag frame:
/// only `CardMotion` reads the offset.
private struct CardDeck: View {
    let deck: [PHAsset]
    let size: CGSize
    let motion: DeckMotion
    let threshold: CGFloat
    let zoom: (String) -> Void
    let act: (SessionOutcome) -> Void
    let fileIntoAlbum: () -> Void
    let springBack: () -> Void

    var body: some View {
        ZStack {
            // One list for the whole deck, so a card keeps its identity (and loaded image)
            // when it moves up. Upcoming cards wait behind the top one, already loading.
            ForEach(Array(deck.enumerated().reversed()), id: \.element.localIdentifier) { index, card in
                let top = index == 0
                SortCard(asset: card, size: size) { zoom(card.localIdentifier) }
                    .modifier(CardMotion(motion: motion, top: top, threshold: threshold))
                    .scaleEffect(top ? 1 : index == 1 ? 0.96 : 0.92)
                    .gesture(drag, including: top ? .all : .none)
                    .allowsHitTesting(top)
                    .zIndex(Double(-index))
                    .accessibilityHidden(!top)
                    .accessibilityAction(named: "Keep") { act(.keep) }
                    .accessibilityAction(named: "Mark for deletion") { act(.mark) }
                    .accessibilityAction(named: "Skip") { act(.skip) }
                    .accessibilityAction(named: "Add to album") { fileIntoAlbum() }
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !motion.flying else { return }
                motion.offset = SwipeDecision.cardOffset(for: value.translation)
            }
            .onEnded { value in
                guard !motion.flying else { return }
                switch SwipeDecision.classify(translation: value.translation, predicted: value.predictedEndTranslation,
                                              threshold: threshold) {
                case .keep: act(.keep)
                case .mark: act(.mark)
                case .album: fileIntoAlbum()
                case .cancel: springBack()
                }
            }
    }
}

/// Stamps, offset and tilt for a deck card. The only place the drag offset is read (and only for the top card).
private struct CardMotion: ViewModifier {
    let motion: DeckMotion
    let top: Bool
    let threshold: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let offset = top ? motion.offset : .zero
        content
            .overlay(alignment: .topLeading) { stamp("Keep", .appSuccess).opacity(top ? keepAmount(offset) : 0) }
            .overlay(alignment: .topTrailing) { stamp("Mark", .appDanger).opacity(top ? markAmount(offset) : 0) }
            .overlay(alignment: .top) {
                stamp("Album", .appAccent).opacity(top ? SwipeDecision.albumAmount(offset: offset, threshold: threshold) : 0)
            }
            .offset(offset)
            .rotationEffect(.degrees(top && !reduceMotion ? Double(offset.width / 30) : 0))
    }

    private func keepAmount(_ offset: CGSize) -> Double {
        SwipeDecision.isUpward(offset) ? 0 : max(0, min(1, (offset.width - 30) / (threshold - 30)))
    }
    private func markAmount(_ offset: CGSize) -> Double {
        SwipeDecision.isUpward(offset) ? 0 : max(0, min(1, (-offset.width - 30) / (threshold - 30)))
    }

    private func stamp(_ text: LocalizedStringKey, _ color: Color) -> some View {
        Text(text)
            .font(.display(22))
            .foregroundStyle(color)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xxs)
            .background(Color.appSurface.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: 3))
            .padding(Space.l)
            .accessibilityHidden(true)
    }
}

/// Large photo card in its original aspect ratio, with date and media info. Videos play inline.
private struct SortCard: View {
    @Environment(PhotoLibrary.self) private var library
    let asset: PHAsset
    let size: CGSize
    let onZoom: () -> Void
    /// Formatted once per card, not on every render.
    private let dateText: String
    private let info: String
    @State private var player: AVPlayer?

    init(asset: PHAsset, size: CGSize, onZoom: @escaping () -> Void) {
        self.asset = asset
        self.size = size
        self.onZoom = onZoom
        dateText = asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "No date")
        info = Self.info(for: asset)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Soft, blurred copy of the photo fills the empty edges, like Apple Photos.
            AssetThumbnail(asset: asset, targetSide: 80, contentMode: .fill, placeholder: Color.appSurface)
                .blur(radius: 28)
                .overlay(Color.black.opacity(0.25))
                .accessibilityHidden(true)

            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    AssetThumbnail(asset: asset, targetSide: max(size.width, size.height), contentMode: .fit,
                                   placeholder: .clear)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { if player == nil { onZoom() } }
            .accessibilityAction(named: "Zoom", onZoom)

            if asset.mediaType == .video && player == nil {
                Button { Task { await play() } } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 64))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.35))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Play video")
            }

            if player == nil {
                HStack(alignment: .bottom, spacing: Space.xs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dateText)
                            .font(.appHeadline)
                        Text(info).font(.appCaption).opacity(0.85)
                    }
                    Spacer()
                    if library.isFavorite(asset) {
                        Image(systemName: "heart.fill").font(.title3).foregroundStyle(Brand.blush)
                            .accessibilityLabel("Favorite")
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 3)
                .padding(Space.m)
                .frame(maxWidth: .infinity)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Swipe right to keep, left to mark for deletion, up to add to an album, or use the actions.")
    }

    private static func info(for asset: PHAsset) -> String {
        var parts: [String] = []
        if asset.mediaType == .video {
            parts.append(String(localized: "Video · \(AssetDescription.duration(asset.duration))"))
        } else if asset.isScreenshot {
            parts.append(String(localized: "Screenshot"))
        } else if asset.isLivePhoto {
            parts.append(String(localized: "Live Photo"))
        } else {
            parts.append(String(localized: "Photo"))
        }
        parts.append("\(asset.pixelWidth)×\(asset.pixelHeight)")
        return parts.joined(separator: " · ")
    }

    private func play() async {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        let a = asset
        let item: AVPlayerItem? = await withCheckedContinuation { c in
            PHImageManager.default().requestPlayerItem(forVideo: a, options: options) { item, _ in
                c.resume(returning: item)
            }
        }
        if let item {
            player = AVPlayer(playerItem: item)
            player?.play()
        }
    }
}

/// End of session: honest counts, then an explicit path to review. No celebration: nothing is deleted yet.
private struct SessionSummary: View {
    let state: SessionState
    let title: String
    let done: () -> Void
    @Environment(ReviewStore.self) private var reviews
    @Environment(Router.self) private var router

    var body: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                ShotsyMascot(mood: .hi).frame(width: 96, height: 96).padding(.top, Space.xxl)
                Text("\(title) sorted").font(.display(24, relativeTo: .title2)).foregroundStyle(Color.appText)
                    .multilineTextAlignment(.center)
                HStack(spacing: Space.s) {
                    stat(state.keptCount, "kept")
                    stat(state.markedCount, "marked")
                    stat(state.skippedCount, "skipped")
                }
                Text("Marked items are still in your library until you review and confirm.")
                    .font(.appCallout).foregroundStyle(Color.appSecondaryText).multilineTextAlignment(.center)
                if reviews.pendingCount > 0 {
                    Button("Review \(reviews.pendingCount) photos") {
                        done()
                        router.sheet = .reviewDeletions
                    }
                    .buttonStyle(.primary)
                }
                Button("Done", action: done).buttonStyle(.secondary)
            }
            .padding(.horizontal, Space.xl)
        }
    }

    private func stat(_ n: Int, _ label: LocalizedStringKey) -> some View {
        VStack(spacing: 2) {
            Text(n, format: .number).font(.display(26)).foregroundStyle(Color.appText)
            Text(label).font(.appFootnote).foregroundStyle(Color.appSecondaryText)
        }
        .frame(maxWidth: .infinity)
        .card(padding: Space.s)
        .accessibilityElement(children: .combine)
    }
}

/// Free daily allowance reached. Undo, reviewing queued items, and deleting them stay available.
struct LimitSheet: View {
    var onClose: () -> Void
    @Environment(Router.self) private var router
    @Environment(ReviewStore.self) private var reviews
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Space.m) {
            ShotsyMascot(mood: .hi).frame(width: 72, height: 72).padding(.top, Space.xl)
            Text("That's today's \(Policy.current.freeDailyReviews) free reviews")
                .font(.display(20, relativeTo: .title3)).multilineTextAlignment(.center)
            Text("You can still undo, and review or delete what you've already marked. Your free reviews reset tomorrow.")
                .font(.appCallout).foregroundStyle(Color.appSecondaryText).multilineTextAlignment(.center)
            Button("See Shotsy Pro") {
                dismiss()
                onClose()
                router.showPaywall(.dailyLimit)
            }
            .buttonStyle(.primary)
            if reviews.pendingCount > 0 {
                Button("Review \(reviews.pendingCount) marked") {
                    dismiss()
                    onClose()
                    router.sheet = .reviewDeletions
                }
                .buttonStyle(.secondary)
            }
            Button("Not now") { dismiss() }.frame(minHeight: Space.minTap)
        }
        .padding(.horizontal, Space.xl)
        .presentationDetents([.medium, .large])
    }
}
