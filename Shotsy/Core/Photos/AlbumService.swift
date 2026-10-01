import Photos

/// An Apple Photos album as Shotsy shows it, with the operations Photos allows on it.
nonisolated struct AlbumInfo: Identifiable, Hashable, Sendable {
    enum Kind: Hashable { case user, shared, synced, smart }

    let id: String
    let title: String
    let kind: Kind
    let count: Int
    let collection: PHAssetCollection

    var canAdd: Bool { collection.canPerform(.addContent) }
    var canRemove: Bool { collection.canPerform(.removeContent) }
    var canRename: Bool { collection.canPerform(.rename) }
    var canDelete: Bool { collection.canPerform(.delete) }
    var isReadOnly: Bool { !canAdd && !canRemove && !canRename }
}

@Observable
final class AlbumService {
    private let library: PhotoLibrary

    init(library: PhotoLibrary) {
        self.library = library
    }

    /// User, shared, and synced albums. Read-only kinds are marked so the UI offers only supported actions.
    /// Counting every album's items is the slow part, so it runs off the main thread.
    func userAlbums() async -> [AlbumInfo] {
        guard library.access.canRead else { return [] }
        return await BackgroundFetch.run { Self.fetchUserAlbums() }
    }

    /// Apple's smart albums that have content (Favorites, Videos, Selfies, ...). Always read-only here.
    func smartAlbums() async -> [AlbumInfo] {
        guard library.access.canRead else { return [] }
        return await BackgroundFetch.run { Self.fetchSmartAlbums() }
    }

    nonisolated private static func fetchUserAlbums() -> [AlbumInfo] {
        var albums: [AlbumInfo] = []
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        result.enumerateObjects { collection, _, _ in
            let kind: AlbumInfo.Kind
            switch collection.assetCollectionSubtype {
            case .albumCloudShared: kind = .shared
            case .albumSyncedAlbum, .albumSyncedEvent, .albumSyncedFaces, .albumImported: kind = .synced
            default: kind = .user
            }
            albums.append(Self.info(collection, kind: kind))
        }
        return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    nonisolated private static func fetchSmartAlbums() -> [AlbumInfo] {
        let wanted: [PHAssetCollectionSubtype] = [
            .smartAlbumFavorites, .smartAlbumVideos, .smartAlbumScreenshots, .smartAlbumSelfPortraits,
            .smartAlbumLivePhotos, .smartAlbumPanoramas, .smartAlbumBursts, .smartAlbumSlomoVideos,
            .smartAlbumDepthEffect, .smartAlbumRAW, .smartAlbumLongExposures, .smartAlbumSpatial,
        ]
        var albums: [AlbumInfo] = []
        for subtype in wanted {
            let result = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
            result.enumerateObjects { collection, _, _ in
                let info = Self.info(collection, kind: .smart)
                if info.count > 0 { albums.append(info) }
            }
        }
        return albums
    }

    func album(id: String) -> AlbumInfo? { Self.album(id: id) }

    nonisolated static func album(id: String) -> AlbumInfo? {
        let result = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil)
        guard let collection = result.firstObject else { return nil }
        let kind: AlbumInfo.Kind = collection.assetCollectionType == .smartAlbum ? .smart
            : collection.assetCollectionSubtype == .albumCloudShared ? .shared : .user
        return Self.info(collection, kind: kind)
    }

    func assets(in album: AlbumInfo) -> PHFetchResult<PHAsset> { Self.assets(in: album) }

    nonisolated static func assets(in album: AlbumInfo) -> PHFetchResult<PHAsset> {
        PHAsset.fetchAssets(in: album.collection, options: PhotoLibrary.options(predicate: PhotoLibrary.photosAndVideos))
    }

    func cover(for album: AlbumInfo) -> PHAsset? {
        let options = PhotoLibrary.options(predicate: PhotoLibrary.photosAndVideos)
        options.fetchLimit = 1
        return PHAsset.fetchKeyAssets(in: album.collection, options: options)?.firstObject
            ?? PHAsset.fetchAssets(in: album.collection, options: options).firstObject
    }

    /// Identifiers in an album, for Smart Collection membership rules. `nil` if the album is gone or inaccessible.
    nonisolated static func memberIDs(albumID: String) -> Set<String>? {
        guard let album = album(id: albumID) else { return nil }
        var ids = Set<String>()
        assets(in: album).enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        return ids
    }

    nonisolated private static func info(_ collection: PHAssetCollection, kind: AlbumInfo.Kind) -> AlbumInfo {
        let count = PHAsset.fetchAssets(in: collection,
                                        options: PhotoLibrary.options(predicate: PhotoLibrary.photosAndVideos)).count
        return AlbumInfo(id: collection.localIdentifier,
                         title: collection.localizedTitle ?? String(localized: "Untitled"),
                         kind: kind, count: count, collection: collection)
    }

    // MARK: Changes (all go through PhotoKit; photos are never copied)

    @discardableResult
    func createAlbum(named name: String) async throws -> String? {
        nonisolated(unsafe) var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholderID = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        return placeholderID
    }

    func rename(_ album: AlbumInfo, to name: String) async throws {
        guard album.canRename else { throw AlbumError.unsupported }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album.collection)?.title = name
        }
    }

    /// Adds existing library assets to an album. The same assets are referenced, not duplicated.
    func add(_ assets: [PHAsset], to album: AlbumInfo) async throws {
        guard album.canAdd else { throw AlbumError.unsupported }
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album.collection)?.addAssets(assets as NSArray)
        }
    }

    /// Removes assets from the album only. They stay in the library.
    func remove(_ assets: [PHAsset], from album: AlbumInfo) async throws {
        guard album.canRemove else { throw AlbumError.unsupported }
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album.collection)?.removeAssets(assets as NSArray)
        }
    }

    /// Deletes the album container. Photos in it stay in the library.
    func deleteAlbum(_ album: AlbumInfo) async throws {
        guard album.canDelete else { throw AlbumError.unsupported }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest.deleteAssetCollections([album.collection] as NSArray)
        }
    }
}

enum AlbumError: LocalizedError {
    case unsupported

    var errorDescription: String? {
        String(localized: "Photos doesn't allow this change for this album.")
    }
}
