import AVFoundation
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// What kind of item an asset is, as the info panel names it. Most specific wins.
nonisolated enum AssetKind: Equatable, Sendable {
    case photo, livePhoto, screenshot, portrait, hdr, panorama, burst
    case video, slowMotion, screenRecording, timeLapse

    init(mediaType: PHAssetMediaType, subtypes: PHAssetMediaSubtype, isBurst: Bool) {
        if mediaType == .video {
            if subtypes.contains(.videoScreenRecording) { self = .screenRecording }
            else if subtypes.contains(.videoHighFrameRate) { self = .slowMotion }
            else if subtypes.contains(.videoTimelapse) { self = .timeLapse }
            else { self = .video }
            return
        }
        if subtypes.contains(.photoScreenshot) { self = .screenshot }
        else if isBurst { self = .burst }
        else if subtypes.contains(.photoPanorama) { self = .panorama }
        else if subtypes.contains(.photoDepthEffect) { self = .portrait }
        else if subtypes.contains(.photoLive) { self = .livePhoto }
        else if subtypes.contains(.photoHDR) { self = .hdr }
        else { self = .photo }
    }

    init(_ asset: PHAsset) {
        self.init(mediaType: asset.mediaType, subtypes: asset.mediaSubtypes,
                  isBurst: asset.representsBurst || asset.burstIdentifier != nil)
    }

    var isVideo: Bool { [.video, .slowMotion, .screenRecording, .timeLapse].contains(self) }

    var title: LocalizedStringResource {
        switch self {
        case .photo: "Photo"
        case .livePhoto: "Live Photo"
        case .screenshot: "Screenshot"
        case .portrait: "Portrait"
        case .hdr: "HDR photo"
        case .panorama: "Panorama"
        case .burst: "Burst"
        case .video: "Video"
        case .slowMotion: "Slo-mo"
        case .screenRecording: "Screen recording"
        case .timeLapse: "Time-lapse"
        }
    }

    var systemImage: String {
        switch self {
        case .photo, .hdr: "photo"
        case .livePhoto: "livephoto"
        case .screenshot: "camera.viewfinder"
        case .portrait: "f.cursive.circle"
        case .panorama: "pano"
        case .burst: "square.stack.3d.down.right"
        case .video: "video"
        case .slowMotion: "slowmo"
        case .screenRecording: "record.circle"
        case .timeLapse: "timelapse"
        }
    }
}

/// Camera facts from EXIF/TIFF. Every field is optional; the panel skips what's missing.
nonisolated struct CameraDetails: Equatable, Sendable {
    var camera: String?
    var lens: String?
    var focalLength: Double?
    var focalLength35: Int?
    var aperture: Double?
    var exposure: Double?
    var iso: Int?

    var isEmpty: Bool {
        camera == nil && lens == nil && focalLength == nil && aperture == nil && exposure == nil && iso == nil
    }

    /// Reads from an ImageIO properties dictionary (`CGImageSourceCopyPropertiesAtIndex`).
    init(properties: [String: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        camera = AssetInfoFormat.cameraName(make: tiff[kCGImagePropertyTIFFMake as String] as? String,
                                            model: tiff[kCGImagePropertyTIFFModel as String] as? String)
        lens = (exif[kCGImagePropertyExifLensModel as String] as? String).flatMap(AssetInfoFormat.trimmed)
        focalLength = Self.positive(exif[kCGImagePropertyExifFocalLength as String])
        focalLength35 = Self.positive(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String]).map { Int($0.rounded()) }
        aperture = Self.positive(exif[kCGImagePropertyExifFNumber as String])
        exposure = Self.positive(exif[kCGImagePropertyExifExposureTime as String])
        let ratings = exif[kCGImagePropertyExifISOSpeedRatings as String]
        iso = Self.positive((ratings as? [NSNumber])?.first ?? ratings).map { Int($0.rounded()) }
    }

    private static func positive(_ value: Any?) -> Double? {
        let number: Double? = switch value {
        case let n as NSNumber: n.doubleValue
        case let d as Double: d
        case let i as Int: Double(i)
        default: nil
        }
        guard let number, number.isFinite, number > 0 else { return nil }
        return number
    }
}

/// Pure formatting for the info panel. Locale is injectable so tests are stable.
nonisolated enum AssetInfoFormat {
    static func resolution(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        return "\(width) × \(height)"
    }

    /// "12 MP", "0.3 MP". Measured from pixel dimensions, not file size.
    static func megapixels(width: Int, height: Int, locale: Locale = .current) -> String? {
        guard width > 0, height > 0 else { return nil }
        let mp = Double(width) * Double(height) / 1_000_000
        return number(mp, digits: mp >= 10 ? 0...0 : 0...1, locale: locale) + " MP"
    }

    /// "1/125 s" below a second, "2 s" or "1.5 s" above.
    static func shutterSpeed(_ seconds: Double, locale: Locale = .current) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds >= 1 { return number(seconds, digits: 0...1, locale: locale) + " s" }
        return "1/\(Int((1 / seconds).rounded())) s"
    }

    static func aperture(_ fNumber: Double, locale: Locale = .current) -> String? {
        guard fNumber.isFinite, fNumber > 0 else { return nil }
        return "ƒ/" + number(fNumber, digits: 0...1, locale: locale)
    }

    static func focalLength(_ mm: Double, locale: Locale = .current) -> String? {
        guard mm.isFinite, mm > 0 else { return nil }
        return number(mm, digits: 0...1, locale: locale) + " mm"
    }

    static func iso(_ value: Int) -> String? { value > 0 ? "ISO \(value)" : nil }

    static func frameRate(_ fps: Float) -> String? {
        guard fps.isFinite, fps > 0 else { return nil }
        return "\(Int(fps.rounded())) fps"
    }

    /// Short format name from a resource's uniform type: "HEIC", "JPEG", "PNG", "MOV".
    static func formatName(uti: String) -> String? {
        guard let type = UTType(uti) else { return nil }
        if type.conforms(to: .jpeg) { return "JPEG" }
        if let ext = type.preferredFilenameExtension { return ext.uppercased() }
        return type.localizedDescription
    }

    static func isHEIF(uti: String) -> Bool {
        guard let type = UTType(uti) else { return false }
        return type.conforms(to: .heic) || type.conforms(to: .heif)
    }

    /// Decimal degrees, fixed digits and separators so they read the same everywhere.
    static func coordinate(latitude: Double, longitude: Double) -> String {
        String(format: "%.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "Apple iPhone 16 Pro"; drops the make when the model already starts with it ("Canon EOS R5").
    static func cameraName(make: String?, model: String?) -> String? {
        let make = make.flatMap(trimmed), model = model.flatMap(trimmed)
        switch (make, model) {
        case let (make?, model?):
            return model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)"
        case let (make?, nil): return make
        case let (nil, model?): return model
        default: return nil
        }
    }

    static func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return value.isEmpty ? nil : value
    }

    private static func number(_ value: Double, digits: ClosedRange<Int>, locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(locale))
    }
}

/// Result of measuring an original resource by reading it.
nonisolated enum MeasuredSize: Equatable, Sendable {
    case bytes(Int64)
    /// The original isn't on this iPhone and network access wasn't allowed.
    case inCloud
    case failed
}

/// Reads camera details from the first bytes of a file as they stream in, so measuring a photo's size can also
/// fill the Camera section without loading the whole image a second time. Buffers at most `limit` bytes;
/// past that (metadata stored late, or none at all) it stops and the caller falls back to a full read.
/// Not thread-safe: feed it from one serial stream.
nonisolated final class StreamedCameraReader {
    static let defaultLimit = 4 << 20

    private let limit: Int
    private var buffer: NSMutableData? = NSMutableData()
    private let source = CGImageSourceCreateIncremental(nil)
    /// Camera facts found in the metadata (nil if it held none).
    private(set) var details: CameraDetails?
    /// EXIF metadata was found, so `details` is final.
    private(set) var isFinished = false

    init(limit: Int = StreamedCameraReader.defaultLimit) {
        self.limit = limit
    }

    /// Still buffering: neither finished nor over the limit.
    var isReading: Bool { buffer != nil }

    func append(_ chunk: Data) {
        guard let buffer else { return }
        buffer.append(chunk)
        CGImageSourceUpdateData(source, buffer, false)
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           properties[kCGImagePropertyExifDictionary as String] != nil {
            let found = CameraDetails(properties: properties)
            details = found.isEmpty ? nil : found
            isFinished = true
            self.buffer = nil
        } else if buffer.length >= limit {
            self.buffer = nil
        }
    }
}

/// Reads facts about one asset off the main actor. Everything is local unless a call says otherwise,
/// and nothing read here is logged.
nonisolated enum AssetInfoReader {
    /// The original photo or video resource (not an edit render, not a Live Photo's paired video).
    static func primaryResource(of asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first { $0.type == .photo || $0.type == .video }
            ?? resources.first { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }
            ?? resources.first
    }

    static func asset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// Counts the bytes of the primary resource by streaming it; chunks are dropped right away.
    /// Without `allowNetwork`, an original that's only in iCloud returns `.inCloud`. Cancellable.
    @concurrent
    static func measureSize(assetID: String, allowNetwork: Bool,
                            progress: (@Sendable (Double) -> Void)? = nil) async -> MeasuredSize {
        await streamPrimaryResource(assetID: assetID, allowNetwork: allowNetwork, camera: nil, progress: progress)
    }

    /// Measures a local photo's original and reads its camera details from the same stream (only the first
    /// few MB are kept for that). `cameraRead` is false if the metadata wasn't in those bytes; then call
    /// `cameraDetails(assetID:)` afterwards rather than alongside, so two full reads never overlap.
    @concurrent
    static func measureSizeReadingCamera(assetID: String) async
        -> (size: MeasuredSize, camera: CameraDetails?, cameraRead: Bool) {
        let reader = StreamedCameraReader()
        let size = await streamPrimaryResource(assetID: assetID, allowNetwork: false, camera: reader, progress: nil)
        // The stream has completed, so nothing else touches the reader now.
        return (size, reader.details, reader.isFinished)
    }

    private static func streamPrimaryResource(assetID: String, allowNetwork: Bool, camera: StreamedCameraReader?,
                                              progress: (@Sendable (Double) -> Void)?) async -> MeasuredSize {
        guard let asset = asset(assetID), let resource = primaryResource(of: asset) else { return .failed }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        if let progress { options.progressHandler = { progress($0) } }
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var count: Int64 = 0
            var request: PHAssetResourceDataRequestID?
            var camera: StreamedCameraReader?
        }
        let box = Box()
        box.camera = camera
        nonisolated(unsafe) let r = resource
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<MeasuredSize, Never>) in
                let id = PHAssetResourceManager.default().requestData(for: r, options: options) { chunk in
                    box.lock.withLock {
                        box.count += Int64(chunk.count)
                        if let reader = box.camera, reader.isReading { reader.append(chunk) }
                    }
                } completionHandler: { error in
                    if let error {
                        continuation.resume(returning: Self.needsNetwork(error) ? .inCloud : .failed)
                    } else {
                        continuation.resume(returning: .bytes(box.lock.withLock { box.count }))
                    }
                }
                box.lock.withLock { box.request = id }
                // Cancelled before the ID was stored: onCancel saw nothing to cancel, so cancel here.
                if Task.isCancelled { PHAssetResourceManager.default().cancelDataRequest(id) }
            }
        } onCancel: {
            if let id = box.lock.withLock({ box.request }) { PHAssetResourceManager.default().cancelDataRequest(id) }
        }
    }

    private static func needsNetwork(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == PHPhotosErrorDomain && ns.code == PHPhotosError.networkAccessRequired.rawValue
    }

    /// Camera details from the local image's metadata. Returns nil for videos, iCloud-only photos, or no EXIF.
    @concurrent
    static func cameraDetails(assetID: String) async -> CameraDetails? {
        guard let asset = asset(assetID), asset.mediaType == .image else { return nil }
        guard let data = await imageData(for: asset, allowNetwork: false, progress: nil)?.data else { return nil }
        // Properties only: ImageIO reads the metadata without decoding pixels.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        let details = CameraDetails(properties: properties)
        return details.isEmpty ? nil : details
    }

    /// Image data for the current version (what Photos shows, including edits). Cancellable.
    static func imageData(for asset: PHAsset, allowNetwork: Bool,
                          progress: (@Sendable (Double) -> Void)?) async -> (data: Data, uti: String?)? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.version = .current
        options.deliveryMode = .highQualityFormat
        if let progress { options.progressHandler = { value, _, _, _ in progress(value) } }
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var request: PHImageRequestID?
        }
        let box = Box()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let id = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                    continuation.resume(returning: data.map { ($0, uti) })
                }
                box.lock.withLock { box.request = id }
                // Cancelled before the ID was stored: onCancel saw nothing to cancel, so cancel here.
                if Task.isCancelled { PHImageManager.default().cancelImageRequest(id) }
            }
        } onCancel: {
            if let id = box.lock.withLock({ box.request }) { PHImageManager.default().cancelImageRequest(id) }
        }
    }

    /// Size of a local video's original file from the file system (no read of its contents). Nil if it's
    /// only in iCloud or Photos doesn't hand back a single file (slo-mo compositions).
    @concurrent
    static func localVideoBytes(assetID: String) async -> Int64? {
        guard let asset = asset(assetID), asset.mediaType == .video else { return nil }
        return await ImageAnalyzer.localVideoBytes(for: asset)
    }

    /// Nominal frame rate of a local video. Nil if it's only in iCloud.
    @concurrent
    static func frameRate(assetID: String) async -> Float? {
        guard let asset = asset(assetID), asset.mediaType == .video else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.version = .original
        nonisolated(unsafe) let requestOptions = options
        let av: AVAsset? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: requestOptions) { av, _, _ in
                nonisolated(unsafe) let av = av
                continuation.resume(returning: av)
            }
        }
        guard let track = try? await av?.loadTracks(withMediaType: .video).first,
              let fps = try? await track.load(.nominalFrameRate), fps > 0 else { return nil }
        return fps
    }

    /// Titles of the user's albums that contain the asset, sorted for display.
    @concurrent
    static func albumTitles(assetID: String) async -> [String] {
        guard let asset = asset(assetID) else { return [] }
        let albums = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var titles: [String] = []
        albums.enumerateObjects { album, _, _ in
            if let title = album.localizedTitle.flatMap(AssetInfoFormat.trimmed) { titles.append(title) }
        }
        return titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
