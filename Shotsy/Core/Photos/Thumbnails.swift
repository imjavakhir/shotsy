import Photos
import SwiftUI

/// Shared caching image manager for grids. Thumbnails never download originals;
/// cloud-only assets fall back to whatever preview Photos has locally.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    let manager = PHCachingImageManager()

    private init() {}

    static func gridOptions(allowNetwork: Bool = false) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork
        return options
    }

    func startCaching(_ assets: [PHAsset], size: CGSize) {
        manager.startCachingImages(for: assets, targetSize: size, contentMode: .aspectFill, options: Self.gridOptions())
    }

    func stopCaching(_ assets: [PHAsset], size: CGSize) {
        manager.stopCachingImages(for: assets, targetSize: size, contentMode: .aspectFill, options: Self.gridOptions())
    }

    func clear() { manager.stopCachingImagesForAllAssets() }
}

/// Streams an image for an asset: a degraded preview first, then the final one. Cancelled with the task.
nonisolated struct ImageStream {
    struct Update: @unchecked Sendable {
        let image: UIImage?
        let isDegraded: Bool
        let isInCloud: Bool
        let error: Error?
    }

    static func images(for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode,
                       options: PHImageRequestOptions, manager: PHImageManager) -> AsyncStream<Update> {
        nonisolated(unsafe) let options = options
        return AsyncStream { continuation in
            let id = manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode,
                                          options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                let error = info?[PHImageErrorKey] as? Error
                if cancelled { continuation.finish(); return }
                continuation.yield(Update(image: image, isDegraded: degraded, isInCloud: inCloud, error: error))
                if !degraded { continuation.finish() }
            }
            continuation.onTermination = { _ in manager.cancelImageRequest(id) }
        }
    }
}

/// Grid/list thumbnail. Always square-cropped unless `contentMode` is `.fit`.
struct AssetThumbnail: View {
    let asset: PHAsset
    var targetSide: CGFloat = 200
    var contentMode: ContentMode = .fill
    var placeholder: Color = .appChip

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(placeholder)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    Image(systemName: asset.mediaType == .video ? "video" : "photo")
                        .foregroundStyle(Color.appSecondaryText.opacity(0.5))
                }
            }
            .clipped()
            .task(id: "\(asset.localIdentifier)-\(Int(targetSide))") { await load() }
            .accessibilityLabel(AssetDescription.label(for: asset))
    }

    private func load() async {
        // Layout may not have a size yet; wait for a real one instead of caching a tiny image.
        guard targetSide >= 1 else { return }
        let side = targetSide * displayScale
        // Large displays (sort card, detail) get an exact-size image and may fetch from iCloud,
        // since the user is looking at this specific item. Grid thumbnails stay local and fast.
        let large = targetSide > 300
        let options = ThumbnailCache.gridOptions(allowNetwork: large)
        if large { options.resizeMode = .exact }
        let stream = ImageStream.images(for: asset, targetSize: CGSize(width: side, height: side),
                                        contentMode: contentMode == .fill ? .aspectFill : .aspectFit,
                                        options: options,
                                        manager: large ? PHImageManager.default() : ThumbnailCache.shared.manager)
        for await update in stream {
            if let img = update.image { image = img }
        }
    }
}

nonisolated enum AssetDescription {
    static func label(for asset: PHAsset) -> String {
        let kind: String
        if asset.mediaType == .video {
            kind = String(localized: "Video")
        } else if asset.isScreenshot {
            kind = String(localized: "Screenshot")
        } else if asset.isLivePhoto {
            kind = String(localized: "Live Photo")
        } else {
            kind = String(localized: "Photo")
        }
        guard let date = asset.creationDate else { return kind }
        return "\(kind), \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: seconds) ?? ""
    }
}

/// Square, clipped thumbnail that never grows past its cell.
struct SquareThumbnail: View {
    let asset: PHAsset
    var targetSide: CGFloat = 200

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { AssetThumbnail(asset: asset, targetSide: targetSide) }
            .clipped()
    }
}
