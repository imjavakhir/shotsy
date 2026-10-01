import AVFoundation
import Photos
import SwiftData
import SwiftUI

nonisolated enum CompressionPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    /// HEVC at up to 1080p. Keeps HDR.
    case hevc1080
    /// HEVC at the original resolution (re-encoded). Keeps HDR.
    case hevcOriginalSize
    /// H.264 at up to 720p. Converts HDR to standard range.
    case h264_720

    var id: String { rawValue }

    var avPreset: String {
        switch self {
        case .hevc1080: AVAssetExportPresetHEVC1920x1080
        case .hevcOriginalSize: AVAssetExportPresetHEVCHighestQuality
        case .h264_720: AVAssetExportPreset1280x720
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .hevc1080: "Balanced · HEVC up to 1080p"
        case .hevcOriginalSize: "Same resolution · HEVC"
        case .h264_720: "Smallest · 720p"
        }
    }

    var keepsHDR: Bool { self != .h264_720 }
    var maxHeight: CGFloat? {
        switch self {
        case .hevc1080: 1080
        case .hevcOriginalSize: nil
        case .h264_720: 720
        }
    }
}

nonisolated struct VideoSourceInfo: Sendable, Equatable {
    var duration: TimeInterval
    var size: CGSize
    var bytes: Int64?
    var isHDR: Bool
    var frameRate: Float
    var isSlowMotion: Bool
    var isCinematic: Bool
    var isSpatial: Bool
    var hasAudio: Bool
}

nonisolated enum CompressionPolicy {
    enum Availability: Equatable, Sendable {
        case available(notes: [String])
        case unavailable(reason: String)
    }

    /// Which presets make sense for this source, and what would be lost.
    static func availability(of preset: CompressionPreset, for info: VideoSourceInfo) -> Availability {
        if info.isSpatial {
            return .unavailable(reason: String(localized: "Spatial video can't be compressed without losing its 3D depth."))
        }
        let shortSide = min(info.size.width, info.size.height)
        if let maxHeight = preset.maxHeight, shortSide <= maxHeight, preset != .hevcOriginalSize {
            return .unavailable(reason: String(localized: "The video is already this size or smaller."))
        }
        var notes: [String] = []
        if info.isHDR && !preset.keepsHDR { notes.append(String(localized: "HDR becomes standard dynamic range.")) }
        if info.isCinematic { notes.append(String(localized: "Cinematic focus can't be edited afterward.")) }
        if info.isSlowMotion { notes.append(String(localized: "Slow motion is saved as it plays now and can't be adjusted later.")) }
        return .available(notes: notes)
    }

    enum Verdict: Equatable, Sendable {
        case smaller(saving: Int64)
        case notSmaller
    }

    static func verdict(sourceBytes: Int64?, outputBytes: Int64) -> Verdict {
        guard let source = sourceBytes, outputBytes < source else { return .notSmaller }
        return .smaller(saving: source - outputBytes)
    }

    /// Needs room for the export plus a safety margin.
    static func hasSpace(available: Int64, estimatedOutput: Int64?, sourceBytes: Int64?) -> Bool {
        let need = (estimatedOutput ?? sourceBytes ?? 500_000_000) * 12 / 10 + 50_000_000
        return available >= need
    }
}

/// One compression at a time: load source → export to a temp file → validate → preview → save as a NEW asset.
/// The original is never modified or removed here.
@Observable
final class CompressionStore {
    enum State: Equatable {
        case idle
        case loadingSource(progress: Double)
        case ready(VideoSourceInfo)
        case exporting(progress: Double)
        case validating
        case preview(url: URL, outputBytes: Int64, verdict: CompressionPolicy.Verdict)
        case saving
        case saved(newAssetID: String, saving: Int64?)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var estimatedBytes: Int64?
    private(set) var sourceAssetID: String?
    private(set) var interruptedJobs = 0

    private let context: ModelContext
    private let library: PhotoLibrary
    @ObservationIgnored private var avAsset: AVAsset?
    @ObservationIgnored private var info: VideoSourceInfo?
    @ObservationIgnored private var job: CompressionJobRecord?
    @ObservationIgnored private var work: Task<Void, Never>?

    init(context: ModelContext, library: PhotoLibrary) {
        self.context = context
        self.library = library
    }

    static var tempDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Compression", isDirectory: true)
    }

    /// On launch: remove leftover temp files and mark jobs that were cut off.
    func cleanAbandonedFiles() {
        try? FileManager.default.removeItem(at: Self.tempDirectory)
        let active = ["exporting", "validating", "preview", "loading"]
        let jobs = (try? context.fetch(FetchDescriptor<CompressionJobRecord>())) ?? []
        var interrupted = 0
        for job in jobs where active.contains(job.stateRaw) {
            job.stateRaw = "interrupted"
            job.errorMessage = String(localized: "Stopped before finishing. The original wasn't changed.")
            interrupted += 1
        }
        // A save that was cut off can't be confirmed; never auto-retry (that could import twice).
        for job in jobs where job.stateRaw == "saving" {
            job.stateRaw = "unconfirmed"
            job.errorMessage = String(localized: "Saving was interrupted. Check Recents in Photos before trying again.")
        }
        interruptedJobs = interrupted
        try? context.save()
    }

    // MARK: Flow

    func load(_ asset: PHAsset) {
        reset()
        sourceAssetID = asset.localIdentifier
        state = .loadingSource(progress: 0)
        work = Task { [weak self] in await self?.loadSource(asset) }
    }

    private func loadSource(_ asset: PHAsset) async {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true // explicit: the user chose to compress this video
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.progressHandler = { [weak self] progress, _, _, _ in
            Task { @MainActor in self?.state = .loadingSource(progress: progress) }
        }
        let source = asset
        nonisolated(unsafe) let requestOptions = options
        let loaded: AVAsset? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: source, options: requestOptions) { av, _, _ in
                nonisolated(unsafe) let av = av
                continuation.resume(returning: av)
            }
        }
        guard !Task.isCancelled else { return }
        guard let loaded else {
            state = .failed(String(localized: "Couldn't load this video. If it's in iCloud, check your connection."))
            return
        }
        avAsset = loaded
        let info = await Self.inspect(loaded, asset: asset)
        self.info = info
        state = .ready(info)
    }

    static func inspect(_ av: AVAsset, asset: PHAsset) async -> VideoSourceInfo {
        let tracks = (try? await av.loadTracks(withMediaType: .video)) ?? []
        let audio = (try? await av.loadTracks(withMediaType: .audio)) ?? []
        var size = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
        var fps: Float = 30
        if let track = tracks.first {
            if let natural = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let r = CGRect(origin: .zero, size: natural).applying(transform)
                size = CGSize(width: abs(r.width), height: abs(r.height))
            }
            fps = (try? await track.load(.nominalFrameRate)) ?? fps
        }
        let hdr = !(((try? await av.loadTracks(withMediaCharacteristic: .containsHDRVideo)) ?? []).isEmpty)
        var bytes: Int64?
        if let url = (av as? AVURLAsset)?.url, let s = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            bytes = Int64(s)
        }
        return VideoSourceInfo(
            duration: asset.duration, size: size, bytes: bytes, isHDR: hdr, frameRate: fps,
            isSlowMotion: asset.mediaSubtypes.contains(.videoHighFrameRate),
            isCinematic: asset.mediaSubtypes.contains(.videoCinematic),
            isSpatial: asset.mediaSubtypes.contains(.spatialMedia),
            hasAudio: !audio.isEmpty)
    }

    func estimate(_ preset: CompressionPreset) async {
        estimatedBytes = nil
        guard let avAsset, let session = AVAssetExportSession(asset: avAsset, presetName: preset.avPreset) else { return }
        session.outputFileType = .mp4
        if let value = try? await session.estimatedOutputFileLengthInBytes, value > 0 {
            estimatedBytes = value
        }
    }

    /// Caller must check Pro first. A job already running keeps its result even if access changes.
    func start(_ preset: CompressionPreset) {
        guard let avAsset, let info, let sourceID = sourceAssetID else { return }
        if case .unavailable(let reason) = CompressionPolicy.availability(of: preset, for: info) {
            state = .failed(reason)
            return
        }
        let available = (try? URL.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        guard CompressionPolicy.hasSpace(available: available, estimatedOutput: estimatedBytes, sourceBytes: info.bytes) else {
            state = .failed(String(localized: "Not enough free space on this iPhone to make a compressed copy."))
            return
        }
        let record = CompressionJobRecord(sourceAssetID: sourceID, presetRaw: preset.rawValue, stateRaw: "exporting")
        record.sourceBytes = info.bytes
        context.insert(record)
        try? context.save()
        job = record
        state = .exporting(progress: 0)
        work = Task { [weak self] in await self?.export(avAsset, preset: preset, info: info) }
    }

    private func export(_ avAsset: AVAsset, preset: CompressionPreset, info: VideoSourceInfo) async {
        guard let session = AVAssetExportSession(asset: avAsset, presetName: preset.avPreset) else {
            fail(String(localized: "This video can't be compressed with that option."))
            return
        }
        try? FileManager.default.createDirectory(at: Self.tempDirectory, withIntermediateDirectories: true)
        let url = Self.tempDirectory.appendingPathComponent("\(job?.id.uuidString ?? UUID().uuidString).mp4")
        job?.tempFileName = url.lastPathComponent
        session.shouldOptimizeForNetworkUse = true
        if let metadata = try? await avAsset.load(.metadata) { session.metadata = metadata }

        let progressTask = Task { [weak self] in
            for await s in session.states(updateInterval: 0.2) {
                if case .exporting(let p) = s {
                    await MainActor.run { self?.state = .exporting(progress: p.fractionCompleted) }
                }
            }
        }
        defer { progressTask.cancel() }
        do {
            try await session.export(to: url, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: url)
            if Task.isCancelled { return }
            fail(error.localizedDescription)
            return
        }
        guard !Task.isCancelled else { try? FileManager.default.removeItem(at: url); return }

        state = .validating
        job?.stateRaw = "validating"
        let output = AVURLAsset(url: url)
        let playable = (try? await output.load(.isPlayable)) ?? false
        let duration = (try? await output.load(.duration).seconds) ?? 0
        let hasVideo = !(((try? await output.loadTracks(withMediaType: .video)) ?? []).isEmpty)
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard playable, hasVideo, bytes > 0, abs(duration - info.duration) < max(1, info.duration * 0.02) else {
            try? FileManager.default.removeItem(at: url)
            fail(String(localized: "The compressed copy didn't pass checks, so it was discarded. The original is unchanged."))
            return
        }
        job?.outputBytes = bytes
        job?.stateRaw = "preview"
        try? context.save()
        state = .preview(url: url, outputBytes: bytes, verdict: CompressionPolicy.verdict(sourceBytes: info.bytes, outputBytes: bytes))
    }

    /// Saves the compressed copy as a new Photos asset, keeping date and location. The original stays.
    func saveCopy() {
        guard case .preview(let url, let bytes, let verdict) = state, let sourceID = sourceAssetID,
              let source = library.asset(for: sourceID) else { return }
        guard case .smaller(let saving) = verdict else { return }
        state = .saving
        job?.stateRaw = "saving"
        try? context.save()
        work = Task { [weak self] in
            nonisolated(unsafe) var placeholder: String?
            let created = source.creationDate
            let location = source.location
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false
                    request.addResource(with: .video, fileURL: url, options: options)
                    request.creationDate = created
                    request.location = location
                    placeholder = request.placeholderForCreatedAsset?.localIdentifier
                }
                try? FileManager.default.removeItem(at: url)
                self?.job?.stateRaw = "saved"
                self?.job?.outputAssetID = placeholder
                try? self?.context.save()
                self?.state = .saved(newAssetID: placeholder ?? "", saving: bytes > 0 ? saving : nil)
            } catch {
                self?.fail(String(localized: "Couldn't save the copy to Photos. The original is unchanged."))
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        if let job, job.stateRaw != "saved" {
            job.stateRaw = "cancelled"
            try? context.save()
        }
        discardTemp()
        state = info.map { .ready($0) } ?? .idle
    }

    func reset() {
        work?.cancel()
        work = nil
        discardTemp()
        avAsset = nil
        info = nil
        job = nil
        estimatedBytes = nil
        sourceAssetID = nil
        state = .idle
    }

    private func discardTemp() {
        if case .preview(let url, _, _) = state { try? FileManager.default.removeItem(at: url) }
    }

    private func fail(_ message: String) {
        job?.stateRaw = "failed"
        job?.errorMessage = message
        try? context.save()
        state = .failed(message)
    }
}
