import Photos
import SwiftUI

nonisolated enum MediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all, photos, videos, screenshots, favorites, unreviewed

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .photos: "Photos"
        case .videos: "Videos"
        case .screenshots: "Screenshots"
        case .favorites: "Favorites"
        case .unreviewed: "Unreviewed"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .photos: "photo"
        case .videos: "video"
        case .screenshots: "camera.viewfinder"
        case .favorites: "heart"
        case .unreviewed: "circle.dashed"
        }
    }
}

/// Access state as the app presents it.
nonisolated enum PhotoAccess: Equatable, Sendable {
    case notDetermined, full, limited, denied, restricted

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized: self = .full
        case .limited: self = .limited
        case .denied: self = .denied
        case .restricted: self = .restricted
        default: self = .notDetermined
        }
    }

    var canRead: Bool { self == .full || self == .limited }
}

/// The user's authorized Photos library. Photos remains the source of truth; Shotsy stores identifiers only.
/// Hidden assets are excluded by default (PHFetchOptions.includeHiddenAssets = false).
@Observable
final class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var access = PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    /// Photos and videos, newest first.
    private(set) var allAssets = PHFetchResult<PHAsset>()
    /// Increments on every observed library change; views use it to refetch.
    private(set) var changeCount = 0
    private(set) var isLoaded = false

    /// Called with identifiers of assets removed from the accessible library (deleted elsewhere or access revoked).
    @ObservationIgnored var onAssetsRemoved: ((Set<String>) -> Void)?
    /// Called after any library change is applied.
    @ObservationIgnored var onChange: (() -> Void)?

    private var observing = false
    /// Favorite changes sent to Photos that haven't come back as a library change yet. The heart flips
    /// right away, and a quick second tap toggles from the new value instead of the stale one.
    private(set) var pendingFavorites: [String: Bool] = [:]

    override init() {
        super.init()
        if access.canRead { start() }
    }

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        applyStatus(status)
    }

    /// Picks up changes made in Settings while the app was in the background.
    func refreshAccess() {
        applyStatus(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    private func applyStatus(_ status: PHAuthorizationStatus) {
        let new = PhotoAccess(status)
        let old = access
        access = new
        if new.canRead {
            // Coming back to the app with unchanged access needs no re-fetch: the change observer already
            // delivers anything that happened in the background.
            if new != old || !observing { start() }
        } else if old.canRead {
            // Access revoked mid-session: drop cached results; decisions stay until assets return or are confirmed gone.
            allAssets = PHFetchResult<PHAsset>()
            changeCount += 1
            onChange?()
        }
    }

    private func start() {
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        reload()
    }

    func reload() {
        allAssets = PHAsset.fetchAssets(with: Self.options(predicate: Self.photosAndVideos))
        isLoaded = true
        changeCount += 1
        onChange?()
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.apply(changeInstance) }
    }

    private func apply(_ change: PHChange) {
        guard let details = change.changeDetails(for: allAssets) else {
            // Album-only change: views refresh, but no asset changed, so analysis has nothing to do.
            changeCount += 1
            return
        }
        let removed = Set(details.removedObjects.map(\.localIdentifier))
        allAssets = details.fetchResultAfterChanges
        // Our own favorite toggles: confirmed now, and they don't change pixels, so no analysis pass.
        var favoriteOnly = !details.changedObjects.isEmpty
        for asset in details.changedObjects {
            let id = asset.localIdentifier
            if let wanted = pendingFavorites[id] {
                if asset.isFavorite == wanted { pendingFavorites[id] = nil }
            } else {
                favoriteOnly = false
            }
        }
        changeCount += 1
        if !removed.isEmpty { onAssetsRemoved?(removed) }
        // Removals are handled above; only new or edited assets need another analysis pass.
        if !details.insertedObjects.isEmpty || (!details.changedObjects.isEmpty && !favoriteOnly) { onChange?() }
    }

    // MARK: Fetching

    nonisolated static var photosAndVideos: NSPredicate {
        NSPredicate(format: "mediaType == %d OR mediaType == %d",
                    PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
    }

    nonisolated static func options(predicate: NSPredicate?, ascending: Bool = false) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = predicate
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: ascending)]
        options.includeHiddenAssets = false
        return options
    }

    nonisolated static func predicate(for filter: MediaFilter) -> NSPredicate {
        switch filter {
        case .all, .unreviewed:
            return photosAndVideos
        case .photos:
            return NSPredicate(format: "mediaType == %d AND NOT ((mediaSubtypes & %d) != 0)",
                               PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoScreenshot.rawValue)
        case .videos:
            return NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case .screenshots:
            return NSPredicate(format: "mediaType == %d AND (mediaSubtypes & %d) != 0",
                               PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoScreenshot.rawValue)
        case .favorites:
            return NSPredicate(format: "(mediaType == %d OR mediaType == %d) AND favorite == YES",
                               PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        }
    }

    func fetch(_ filter: MediaFilter, ascending: Bool = false) -> PHFetchResult<PHAsset> {
        guard access.canRead else { return PHFetchResult<PHAsset>() }
        return PHAsset.fetchAssets(with: Self.options(predicate: Self.predicate(for: filter), ascending: ascending))
    }

    func fetch(predicate: NSPredicate, ascending: Bool = false) -> PHFetchResult<PHAsset> {
        guard access.canRead else { return PHFetchResult<PHAsset>() }
        return PHAsset.fetchAssets(with: Self.options(predicate: predicate, ascending: ascending))
    }

    /// Assets for identifiers, in the given order; missing or inaccessible IDs are skipped.
    func assets(for ids: [String]) -> [PHAsset] {
        // Reading changeCount makes any view that looks up assets re-render after a library change,
        // so it never shows a stale snapshot (e.g. an outdated favorite state).
        _ = changeCount
        guard access.canRead, !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        return ids.compactMap { byID[$0] }
    }

    func asset(for id: String) -> PHAsset? { assets(for: [id]).first }

    /// Identifiers of every accessible photo/video, newest first.
    func allIdentifiers() -> [String] {
        var ids: [String] = []
        ids.reserveCapacity(allAssets.count)
        allAssets.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return ids
    }

    // MARK: Changes

    /// Favorite state including changes still on their way back from Photos.
    func isFavorite(_ asset: PHAsset) -> Bool {
        pendingFavorites[asset.localIdentifier] ?? asset.isFavorite
    }

    func setFavorite(_ assets: [PHAsset], _ favorite: Bool) async throws {
        let editable = assets.filter { $0.canPerform(.properties) && isFavorite($0) != favorite }
        guard !editable.isEmpty else { return }
        let ids = editable.map(\.localIdentifier)
        for id in ids { pendingFavorites[id] = favorite }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for asset in editable {
                    PHAssetChangeRequest(for: asset).isFavorite = favorite
                }
            }
        } catch {
            for id in ids where pendingFavorites[id] == favorite { pendingFavorites[id] = nil }
            throw error
        }
    }
}

extension PHAsset {
    nonisolated var isScreenshot: Bool { mediaSubtypes.contains(.photoScreenshot) }
    nonisolated var isLivePhoto: Bool { mediaSubtypes.contains(.photoLive) }
    nonisolated var pixelCount: Int { pixelWidth * pixelHeight }
}
