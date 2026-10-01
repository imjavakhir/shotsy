import Photos
import SwiftData
import SwiftUI

nonisolated struct VideoItem: Identifiable, Sendable, Equatable {
    var id: String
    var duration: TimeInterval
    /// Measured size of the local original; nil when unknown (e.g. only in iCloud).
    var bytes: Int64?

    /// Measured sizes first (largest first), then unknown sizes (longest first).
    static func bySize(_ items: [VideoItem]) -> [VideoItem] {
        items.filter { $0.bytes != nil }.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
            + items.filter { $0.bytes == nil }.sorted { $0.duration > $1.duration }
    }
}

/// What the Clean dashboard shows. Built only from real analysis results.
struct CategorySummary: Equatable {
    var similar: [SimilarGroup] = []
    var duplicateCandidates: [SimilarGroup] = []
    var blurry: [String] = []
    var screenshotIDs: [String] = []
    var largeVideos: [VideoItem] = []
    var unknownSizeVideos = 0
    var bursts: [BurstGroup] = []
    var screenRecordings: [VideoItem] = []
    var slowMotion: [VideoItem] = []
    /// Pixel counts of photos the categories suggest removing (similar/duplicate non-keepers, blurry,
    /// burst extras). Feeds the storage estimate.
    var candidatePixels: [String: Int] = [:]
    /// Favorites among the photo candidates and videos, so the estimate can leave them out.
    var favoriteIDs: Set<String> = []
    /// Photos not yet analyzed, so categories may be incomplete.
    var isPartial = true
}

/// Runs the on-device analysis passes (photos → screenshot OCR → video sizes) with honest progress,
/// pause/resume/cancel, and results that update as batches finish.
@Observable
final class AnalysisCoordinator {
    enum Phase: Equatable {
        case idle, analyzingPhotos, readingScreenshots, measuringVideos, paused, complete, disabled, noAccess
    }

    private(set) var phase: Phase = .idle
    private(set) var done = 0
    private(set) var total = 0
    private(set) var unavailable = 0
    /// Photos Vision couldn't analyze this time; retried on the next scan.
    private(set) var failed = 0
    private(set) var summary = CategorySummary()
    /// Bumps whenever `summary` is replaced; views key background work on it.
    private(set) var summaryRevision = 0
    private(set) var isSummarizing = false
    /// Groups whose original files were compared byte-for-byte and matched.
    private(set) var verifiedDuplicates: [[String]] = []
    private(set) var verifyingDuplicates = false
    private(set) var verificationNote: String?
    private(set) var supportedOCRLanguages: [String] = []
    /// Automatic scanning is waiting for Low Power Mode to end (Settings → Sync).
    private(set) var heldForLowPower = false

    @ObservationIgnored var isPro: () -> Bool = { false }

    var isPaused: Bool {
        get { UserDefaults.standard.bool(forKey: "analysisPaused") }
        set { UserDefaults.standard.set(newValue, forKey: "analysisPaused") }
    }

    var isRunning: Bool { [.analyzingPhotos, .readingScreenshots, .measuringVideos].contains(phase) }

    private let worker: AnalysisWorker
    private let library: PhotoLibrary
    private let settings: SettingsStore
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The running scan was started by the user (Scan Now, Resume, a settings change), so Sync
    /// settings don't hold it.
    @ObservationIgnored private var userStarted = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var hasSummary = false
    @ObservationIgnored private var lastProgressSummary = Date.distantPast

    init(container: ModelContainer, library: PhotoLibrary, settings: SettingsStore) {
        self.worker = AnalysisWorker(modelContainer: container)
        self.library = library
        self.settings = settings
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.powerStateChanged() }
        }
    }

    private var lowPowerHold: Bool {
        settings.pauseOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func powerStateChanged() {
        if lowPowerHold, isRunning, !userStarted {
            task?.cancel()
            task = nil
            heldForLowPower = true
            phase = .paused
        } else if !lowPowerHold, heldForLowPower {
            heldForLowPower = false
            startIfNeeded()
        }
    }

    // MARK: Control

    /// Automatic start (launch, library changes). Respects Settings → Sync.
    func startIfNeeded() { start(userInitiated: false) }

    /// Settings → Sync → "Scan Now": runs even with automatic scanning off or in Low Power Mode.
    func scanNow() {
        isPaused = false
        start(userInitiated: true)
    }

    private func start(userInitiated: Bool) {
        guard library.access.canRead else { phase = .noAccess; return }
        guard settings.categoryAnalysisEnabled else { phase = .disabled; return }
        guard !isPaused else { phase = .paused; return }
        guard task == nil else { return }
        if !userInitiated {
            if lowPowerHold {
                heldForLowPower = true
                phase = .paused
                if !hasSummary { Task { await summarize() } }
                return
            }
            if !settings.autoScanEnabled {
                // Show results from earlier scans without scanning again.
                if !hasSummary { Task { await summarize() } }
                return
            }
        }
        heldForLowPower = false
        userStarted = userInitiated
        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
            self?.userStarted = false
        }
    }

    func pause() {
        isPaused = true
        task?.cancel()
        task = nil
        phase = .paused
    }

    func resume() {
        isPaused = false
        phase = .idle
        start(userInitiated: true)
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    /// After a settings or Pro change the user just made.
    func restart() {
        cancel()
        start(userInitiated: true)
    }

    /// New or edited assets: re-run after things settle.
    func libraryChanged() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            if self.task == nil { self.startIfNeeded() }
        }
    }

    func forget(_ ids: Set<String>) {
        Task { await worker.forget(ids) }
        verifiedDuplicates = verifiedDuplicates.map { $0.filter { !ids.contains($0) } }.filter { $0.count > 1 }
        // Removed assets must leave the cleanup results: rebuild the summary once things settle.
        hasSummary = false
        libraryChanged()
    }

    /// Settings → "Clear analysis cache". Never touches Photos; results rebuild on the next scan.
    func clearCache() async {
        cancel()
        await worker.clearAll()
        verifiedDuplicates = []
        summary = CategorySummary()
        summaryRevision += 1
        start(userInitiated: true)
    }

    // MARK: Passes

    private func run() async {
        if supportedOCRLanguages.isEmpty { supportedOCRLanguages = ImageAnalyzer.supportedOCRLanguages() }

        // Library reads walk every asset, so they run off the main thread.
        let canRead = library.access.canRead

        // 1. Photos (not screenshots): feature prints + sharpness.
        let items = await BackgroundFetch.run(priority: .utility) { canRead ? AnalysisLibraryRead.photoItems() : [] }
        let needed = await worker.photosNeedingAnalysis(items)
        let counts = await worker.counts()
        unavailable = counts.unavailable
        if !needed.isEmpty {
            phase = .analyzingPhotos
            total = needed.count
            done = 0
            await worker.analyzePhotos(needed) { [weak self] p in
                await self?.report(p)
            }
            if Task.isCancelled { await summarize(); return }
            await summarize()
        } else if !hasSummary {
            await summarize()
        }

        // 2. Screenshot OCR (Pro feature: text search + category suggestions).
        var didOCR = false
        if settings.ocrEnabled, isPro() {
            let ids = await BackgroundFetch.run(priority: .utility) {
                canRead ? AnalysisLibraryRead.identifiers(.screenshots) : []
            }
            let pending = await worker.screenshotsNeedingOCR(ids)
            didOCR = !pending.isEmpty
            if !pending.isEmpty {
                phase = .readingScreenshots
                total = pending.count
                done = 0
                await worker.recognizeScreenshots(pending) { [weak self] p in
                    await self?.report(p)
                }
                if Task.isCancelled { return }
            }
        }

        // 3. Video sizes (local files only).
        phase = .measuringVideos
        let videoIDs = await BackgroundFetch.run(priority: .utility) {
            canRead ? AnalysisLibraryRead.identifiers(.videos) : []
        }
        let measured = await worker.measureVideos(videoIDs)
        if Task.isCancelled { return }
        // Results only change when this pass analyzed something; otherwise skip the full re-summary.
        if !needed.isEmpty || measured > 0 || !hasSummary || didOCR { await summarize() }
        phase = .complete
    }

    private func report(_ p: AnalysisWorker.Progress) async {
        done = p.done
        total = p.total
        // summarize() walks the whole library, so refresh results on a timer rather than per batch.
        if p.done == p.total || Date().timeIntervalSince(lastProgressSummary) > 30 {
            lastProgressSummary = Date()
            await summarize()
        }
    }

    // MARK: Results

    func summarize() async {
        guard library.access.canRead else { summary = CategorySummary(); summaryRevision += 1; return }
        isSummarizing = true
        defer { isSummarizing = false }
        let protect = settings.protectFavorites
        // Every PhotoKit read (photos, screenshots, videos, bursts, screen recordings, slo-mo), off the main thread.
        let read = await BackgroundFetch.run(priority: .utility) { AnalysisLibraryRead.summary(protectFavorites: protect) }
        let meta = read.photoMeta
        let analyzed = await worker.analyzedPhotos(ids: meta)
        let groups = await Task.detached(priority: .utility) {
            SimilarityGrouper.groups(analyzed, protectFavorites: protect)
        }.value

        let sharp = await worker.sharpness(for: read.photoIDs)
        let blurry = sharp.filter { id, value in
            value < SimilarityTuning.blurThreshold && !(protect && (meta[id]?.1 ?? false))
        }.map(\.key).sorted { (meta[$0]?.0 ?? .distantPast) > (meta[$1]?.0 ?? .distantPast) }

        let shots = read.screenshotIDs

        let sizes = await worker.videoBytes()
        var videos: [VideoItem] = []
        videos.reserveCapacity(read.videos.count)
        var favorites = Set<String>()
        for v in read.videos {
            videos.append(VideoItem(id: v.id, duration: v.duration, bytes: sizes[v.id]))
            if v.isFavorite { favorites.insert(v.id) }
        }
        let known = videos.filter { $0.bytes != nil }.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        let unknown = videos.filter { $0.bytes == nil }.sorted { $0.duration > $1.duration }

        // Bursts, screen recordings and slo-mo.
        let special = read.special
        let withSizes = { (ids: [(id: String, duration: TimeInterval)]) in
            VideoItem.bySize(ids.map { VideoItem(id: $0.id, duration: $0.duration, bytes: sizes[$0.id]) })
        }

        // Storage-estimate inputs: photos each category would suggest removing.
        var pixels: [String: Int] = [:]
        func addPhoto(_ id: String) {
            guard let m = meta[id] else { return }
            pixels[id] = m.2 * m.3
            if m.1 { favorites.insert(id) }
        }
        for group in groups { for id in group.ids where id != group.suggestedKeeper { addPhoto(id) } }
        blurry.forEach(addPhoto)
        for group in special.bursts { for id in group.extras { pixels[id] = special.burstPixels[id] ?? 0 } }
        favorites.formUnion(special.burstFavorites)

        let counts = await worker.counts()
        unavailable = counts.unavailable
        failed = counts.failed

        hasSummary = true
        summary = CategorySummary(
            similar: groups.filter { !$0.isDuplicateCandidate },
            duplicateCandidates: groups.filter(\.isDuplicateCandidate),
            blurry: blurry,
            screenshotIDs: shots,
            largeVideos: known + unknown,
            unknownSizeVideos: unknown.count,
            bursts: special.bursts,
            screenRecordings: withSizes(special.screenRecordings),
            slowMotion: withSizes(special.slowMotion),
            candidatePixels: pixels,
            favoriteIDs: favorites,
            isPartial: counts.analyzed + counts.unavailable + counts.failed < meta.count
        )
        summaryRevision += 1
    }

    /// Byte-compares originals of duplicate candidates. Explicit user action; may download from iCloud if allowed.
    func verifyDuplicates(allowNetwork: Bool) async {
        verifyingDuplicates = true
        verificationNote = nil
        defer { verifyingDuplicates = false }
        var verified: [[String]] = []
        var unreadable = 0
        for group in summary.duplicateCandidates {
            if Task.isCancelled { break }
            var prints: [String: [ResourceFingerprint]?] = [:]
            for asset in library.assets(for: group.ids) {
                let p = await ImageAnalyzer.resourceFingerprints(for: asset, allowNetwork: allowNetwork)
                if p == nil { unreadable += 1 }
                prints[asset.localIdentifier] = p
            }
            verified += DuplicateVerification.verifiedGroups(prints)
        }
        verifiedDuplicates = verified
        if unreadable > 0 {
            verificationNote = String(localized: "\(unreadable) originals couldn't be read, so those stay unverified.")
        }
    }
}

/// The PhotoKit reads behind a scan and its summary, returned as plain values. Call off the main thread
/// (`BackgroundFetch.run`) after checking access on the main actor.
nonisolated enum AnalysisLibraryRead {
    struct Summary: Sendable {
        /// Photos (not screenshots): creation date, favorite, pixel width, pixel height.
        var photoMeta: [String: (Date, Bool, Int, Int)] = [:]
        var photoIDs = Set<String>()
        var screenshotIDs: [String] = []
        var videos: [(id: String, duration: TimeInterval, isFavorite: Bool)] = []
        var special = SpecialMediaFetch()
    }

    /// Everything `AnalysisCoordinator.summarize()` reads from Photos, in one pass per fetch.
    static func summary(protectFavorites: Bool) -> Summary {
        var out = Summary()
        let photos = BackgroundFetch.fetch(.photos)
        out.photoMeta.reserveCapacity(photos.count)
        photos.enumerateObjects { a, _, _ in
            out.photoMeta[a.localIdentifier] = (a.creationDate ?? .distantPast, a.isFavorite, a.pixelWidth, a.pixelHeight)
        }
        out.photoIDs = Set(out.photoMeta.keys)
        out.screenshotIDs = identifiers(.screenshots)
        let videos = BackgroundFetch.fetch(.videos)
        out.videos.reserveCapacity(videos.count)
        videos.enumerateObjects { a, _, _ in out.videos.append((a.localIdentifier, a.duration, a.isFavorite)) }
        out.special = SpecialMediaFetch.read(protectFavorites: protectFavorites)
        return out
    }

    /// Photos (not screenshots) with their modification dates, for deciding what needs analysis.
    static func photoItems() -> [(id: String, modified: Date?)] {
        let photos = BackgroundFetch.fetch(.photos)
        var items: [(id: String, modified: Date?)] = []
        items.reserveCapacity(photos.count)
        photos.enumerateObjects { a, _, _ in items.append((a.localIdentifier, a.modificationDate)) }
        return items
    }

    static func identifiers(_ filter: MediaFilter) -> [String] {
        BackgroundFetch.identifiers(in: BackgroundFetch.fetch(filter))
    }
}

/// Bursts, screen recordings and slo-mo videos. Cheap PhotoKit fetches; call off the main thread.
nonisolated struct SpecialMediaFetch: Sendable {
    var bursts: [BurstGroup] = []
    var burstPixels: [String: Int] = [:]
    var burstFavorites: Set<String> = []
    var screenRecordings: [(id: String, duration: TimeInterval)] = []
    var slowMotion: [(id: String, duration: TimeInterval)] = []

    static func read(protectFavorites: Bool) -> SpecialMediaFetch {
        var out = SpecialMediaFetch()

        let burstOptions = PhotoLibrary.options(predicate: NSPredicate(format: "burstIdentifier != nil"))
        burstOptions.includeAllBurstAssets = true
        var members: [BurstMember] = []
        PHAsset.fetchAssets(with: burstOptions).enumerateObjects { a, _, _ in
            guard let burstID = a.burstIdentifier else { return }
            let types = a.burstSelectionTypes
            members.append(BurstMember(id: a.localIdentifier, burstID: burstID,
                                       isUserPick: types.contains(.userPick), isAutoPick: types.contains(.autoPick),
                                       representsBurst: a.representsBurst, isFavorite: a.isFavorite,
                                       date: a.creationDate, pixelCount: a.pixelCount))
        }
        out.bursts = BurstPlanner.groups(members, protectFavorites: protectFavorites)
        for m in members {
            out.burstPixels[m.id] = m.pixelCount
            if m.isFavorite { out.burstFavorites.insert(m.id) }
        }

        out.screenRecordings = videos(subtype: .videoScreenRecording)
        out.slowMotion = videos(subtype: .videoHighFrameRate)
        return out
    }

    private static func videos(subtype: PHAssetMediaSubtype) -> [(id: String, duration: TimeInterval)] {
        let predicate = NSPredicate(format: "mediaType == %d AND (mediaSubtypes & %d) != 0",
                                    PHAssetMediaType.video.rawValue, subtype.rawValue)
        var items: [(id: String, duration: TimeInterval)] = []
        PHAsset.fetchAssets(with: PhotoLibrary.options(predicate: predicate)).enumerateObjects { a, _, _ in
            items.append((a.localIdentifier, a.duration))
        }
        return items
    }
}
