import Photos
import SwiftUI

/// Details for one asset, like the Photos info panel, plus "Save as JPG copy" for HEIC/HEIF photos.
/// Reads are local; the only downloads are the explicit "Download to measure" and the JPG copy.
/// A video is never streamed just to open Info: its size comes from analysis or the local file, or the user taps Measure.
struct AssetInfoSheet: View {
    let assetID: String
    /// The daily review limit was hit. The caller shows its limit sheet (the app-level paywall sits behind the preview).
    var onLimit: () -> Void

    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var reviews
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(\.dismiss) private var dismiss

    enum SizeState: Equatable {
        case measuring, downloading(Double), measured(Int64), inCloud, unknown
        /// A video whose size isn't known yet. Measuring reads the whole file, so it waits for a tap.
        case notMeasured
        /// Reading a local original after the user asked. Cancellable.
        case reading
    }

    enum CopyState: Equatable {
        case idle, loading(Double), saving, saved, failed(String)
    }

    /// Resolved once in `load()` (and after library changes), not on every render or progress tick.
    @State private var asset: PHAsset?
    @State private var resolved = false
    @State private var filename: String?
    @State private var uti: String?
    @State private var size: SizeState = .measuring
    @State private var camera: CameraDetails?
    @State private var frameRate: Float?
    @State private var albums: [String]?
    @State private var sizeTask: Task<Void, Never>?
    @State private var copy: CopyState = .idle
    @State private var copyTask: Task<Void, Never>?
    @State private var markMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let asset {
                    Group {
                        summarySection(asset)
                        fileSection(asset)
                        if let camera { cameraSection(camera) }
                        if let location = asset.location {
                            Section("Location") {
                                LabeledContent("Coordinates", value: AssetInfoFormat.coordinate(
                                    latitude: location.coordinate.latitude, longitude: location.coordinate.longitude))
                                    .textSelection(.enabled)
                            }
                        }
                        albumsSection
                        if asset.mediaType == .image, let uti, AssetInfoFormat.isHEIF(uti: uti) {
                            copySection(asset)
                        }
                    }
                    .listRowBackground(Color.appSurface)
                } else if resolved {
                    Text("This item was deleted or Shotsy can no longer access it.")
                }
            }
            .scrollContentBackground(.hidden)
            .softAppBar()
            .pageBackground()
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task(id: assetID) { await load() }
        .onChange(of: library.changeCount) { if resolved { asset = library.asset(for: assetID) } }
        .onDisappear {
            sizeTask?.cancel()
            // A download for the copy stops with the sheet; a save already handed to Photos finishes.
            if case .loading = copy { copyTask?.cancel() }
        }
    }

    // MARK: Sections

    private func summarySection(_ asset: PHAsset) -> some View {
        let kind = AssetKind(asset)
        return Section {
            HStack(spacing: Space.s) {
                AssetThumbnail(asset: asset, targetSide: 100)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Label { Text(kind.title) } icon: { Image(systemName: kind.systemImage) }
                        .font(.appHeadline)
                    if let date = asset.creationDate {
                        Text(date.formatted(date: .complete, time: .shortened))
                            .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                    }
                }
            }
            if let created = asset.creationDate {
                LabeledContent("Taken", value: created.formatted(date: .abbreviated, time: .standard))
                if let modified = asset.modificationDate, abs(modified.timeIntervalSince(created)) >= 1 {
                    LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .standard))
                }
            }
            LabeledContent("Favorite", value: library.isFavorite(asset) ? String(localized: "Yes") : String(localized: "No"))
        }
    }

    private func fileSection(_ asset: PHAsset) -> some View {
        Section {
            if let filename { LabeledContent("File name", value: filename).textSelection(.enabled) }
            if let format = uti.flatMap(AssetInfoFormat.formatName) { LabeledContent("Format", value: format) }
            if let resolution = AssetInfoFormat.resolution(width: asset.pixelWidth, height: asset.pixelHeight) {
                LabeledContent("Resolution", value: resolution)
            }
            if asset.mediaType == .video {
                LabeledContent("Duration", value: AssetDescription.duration(asset.duration))
                if let fps = frameRate.flatMap(AssetInfoFormat.frameRate) { LabeledContent("Frame rate", value: fps) }
            } else if let mp = AssetInfoFormat.megapixels(width: asset.pixelWidth, height: asset.pixelHeight) {
                LabeledContent("Megapixels", value: mp)
            }
            sizeRow
        } header: {
            Text("File")
        } footer: {
            if case .measured = size {
                Text("Size of the original file, measured on this iPhone.")
            } else if size == .inCloud {
                Text("The original is in iCloud. Measuring downloads it through Photos.")
            }
        }
    }

    @ViewBuilder
    private var sizeRow: some View {
        switch size {
        case .measuring:
            LabeledContent("File size") { ProgressView() }
        case .downloading(let progress):
            LabeledContent("File size") {
                HStack(spacing: Space.xs) {
                    ProgressView(value: progress).frame(width: 80)
                    Button("Cancel") { sizeTask?.cancel() }.font(.appFootnote)
                }
            }
        case .measured(let bytes):
            LabeledContent("File size", value: AssetInfoFormat.bytes(bytes))
        case .inCloud:
            LabeledContent("File size", value: String(localized: "Stored in iCloud"))
            Button("Download to measure", systemImage: "icloud.and.arrow.down") { downloadToMeasure() }
        case .unknown:
            LabeledContent("File size", value: String(localized: "Unknown"))
        case .notMeasured:
            LabeledContent("File size") {
                Button("Measure") { measureLocally() }.font(.appFootnote)
            }
        case .reading:
            LabeledContent("File size") {
                HStack(spacing: Space.xs) {
                    ProgressView()
                    Button("Cancel") { sizeTask?.cancel() }.font(.appFootnote)
                }
            }
        }
    }

    private func cameraSection(_ camera: CameraDetails) -> some View {
        Section("Camera") {
            if let name = camera.camera { LabeledContent("Camera", value: name) }
            if let lens = camera.lens { LabeledContent("Lens", value: lens) }
            if let focal = camera.focalLength.flatMap({ AssetInfoFormat.focalLength($0) }) {
                LabeledContent("Focal length", value: focal)
            }
            if let equivalent = camera.focalLength35.flatMap({ AssetInfoFormat.focalLength(Double($0)) }) {
                LabeledContent("35 mm equivalent", value: equivalent)
            }
            if let aperture = camera.aperture.flatMap({ AssetInfoFormat.aperture($0) }) {
                LabeledContent("Aperture", value: aperture)
            }
            if let shutter = camera.exposure.flatMap({ AssetInfoFormat.shutterSpeed($0) }) {
                LabeledContent("Shutter speed", value: shutter)
            }
            if let iso = camera.iso.flatMap(AssetInfoFormat.iso) { LabeledContent("ISO", value: iso) }
        }
    }

    private var albumsSection: some View {
        Section("Albums") {
            if let albums {
                if albums.isEmpty {
                    Text("Not in any album").foregroundStyle(Color.appSecondaryText)
                } else {
                    ForEach(Array(albums.enumerated()), id: \.offset) { _, title in
                        Label(title, systemImage: "rectangle.stack")
                    }
                }
            } else {
                ProgressView()
            }
        }
    }

    private func copySection(_ asset: PHAsset) -> some View {
        Section {
            switch copy {
            case .idle:
                Button("Save as JPG copy", systemImage: "doc.on.doc") { makeCopy(asset) }
            case .loading(let progress):
                if progress > 0 {
                    ProgressView(value: progress) { Text("Downloading from iCloud") }
                } else {
                    ProgressView { Text("Reading the original") }
                }
                Button("Cancel", role: .cancel) { copyTask?.cancel() }
            case .saving:
                ProgressView { Text("Saving copy to Photos") }
            case .saved:
                Label("JPG copy saved to Photos", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.appSuccess)
                Button("Mark original for deletion", systemImage: "trash") { markOriginal() }
                    .disabled(reviews.decision(for: assetID) == .marked)
                if let markMessage {
                    Text(markMessage).font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                }
            case .failed(let message):
                Notice(kind: .error, text: LocalizedStringKey(message))
                Button("Try again") { makeCopy(asset) }
            }
        } header: {
            Text("JPG copy")
        } footer: {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Adds a new JPG to your library with the same date, location and camera details. The original stays as it is.")
                if asset.isLivePhoto {
                    Text("Only the still photo is copied. The Live Photo motion stays with the original.")
                }
            }
        }
    }

    // MARK: Loading

    private func load() async {
        let asset = library.asset(for: assetID)
        self.asset = asset
        resolved = true
        if let asset, let resource = AssetInfoReader.primaryResource(of: asset) {
            filename = AssetInfoFormat.trimmed(resource.originalFilename)
            uti = resource.uniformTypeIdentifier
        }
        let id = assetID
        let isVideo = asset?.mediaType == .video
        async let albumList = AssetInfoReader.albumTitles(assetID: id)
        async let fps = AssetInfoReader.frameRate(assetID: id)
        albums = await albumList
        frameRate = await fps
        if isVideo {
            // Videos can be several GB: use the size analysis measured, or the local file's size, never a full read.
            let bytes = analyzedVideoBytes(id)
            let measured = bytes == nil ? await AssetInfoReader.localVideoBytes(assetID: id) : bytes
            guard !Task.isCancelled else { return }
            size = measured.map(SizeState.measured) ?? .notMeasured
            return
        }
        // Photos: one stream measures the original and reads its camera details from the first bytes.
        let measured = await AssetInfoReader.measureSizeReadingCamera(assetID: id)
        guard !Task.isCancelled else { return }
        camera = measured.camera
        size = Self.sizeState(measured.size)
        if !measured.cameraRead {
            // Metadata wasn't near the start: read it now, after the size stream, never alongside it.
            let details = await AssetInfoReader.cameraDetails(assetID: id)
            guard !Task.isCancelled else { return }
            camera = details
        }
    }

    /// Size the library analysis measured for this video, if any.
    private func analyzedVideoBytes(_ id: String) -> Int64? {
        let summary = analysis.summary
        for videos in [summary.largeVideos, summary.screenRecordings, summary.slowMotion] {
            if let bytes = videos.first(where: { $0.id == id })?.bytes { return bytes }
        }
        return nil
    }

    private static func sizeState(_ result: MeasuredSize) -> SizeState {
        switch result {
        case .bytes(let count): .measured(count)
        case .inCloud: .inCloud
        case .failed: .unknown
        }
    }

    /// Explicit local read of a video's original, only to count the bytes. Nothing is kept.
    private func measureLocally() {
        size = .reading
        let id = assetID
        sizeTask = Task {
            let result = await AssetInfoReader.measureSize(assetID: id, allowNetwork: false)
            size = Task.isCancelled ? .notMeasured : Self.sizeState(result)
        }
    }

    /// Explicit iCloud download through Photos, only to count the bytes. Nothing is kept.
    private func downloadToMeasure() {
        size = .downloading(0)
        let id = assetID
        sizeTask = Task {
            let result = await AssetInfoReader.measureSize(assetID: id, allowNetwork: true) { progress in
                Task { @MainActor in
                    if case .downloading = size { size = .downloading(progress) }
                }
            }
            size = Task.isCancelled ? .inCloud : Self.sizeState(result)
        }
    }

    // MARK: JPG copy

    private func makeCopy(_ asset: PHAsset) {
        markMessage = nil
        copy = .loading(0)
        let name = ImageConverter.jpegFilename(for: filename)
        let favorite = library.isFavorite(asset)
        copyTask = Task {
            let jpeg: Data
            do {
                // Scoped so the original's bytes are released before the save; only the JPEG stays alive.
                // The Photos/iCloud download is allowed here: the user asked for the copy.
                let source = await AssetInfoReader.imageData(for: asset, allowNetwork: true) { progress in
                    Task { @MainActor in
                        if case .loading = copy { copy = .loading(progress) }
                    }
                }
                guard !Task.isCancelled else { copy = .idle; return }
                guard let data = source?.data else {
                    copy = .failed(String(localized: "Couldn't read this photo. If it's in iCloud, check your connection."))
                    return
                }
                copy = .saving
                guard let converted = try? await ImageConverter.convert(data) else {
                    copy = .failed(String(localized: "Couldn't convert this photo. The original is unchanged."))
                    return
                }
                jpeg = converted
            }
            do {
                _ = try await ImageConverter.saveCopy(jpeg, filename: name, creationDate: asset.creationDate,
                                                      location: asset.location, isFavorite: favorite)
                copy = .saved
            } catch {
                copy = .failed(String(localized: "Couldn't save the copy to Photos. The original is unchanged."))
            }
        }
    }

    private func markOriginal() {
        do {
            try reviews.decide(.marked, ids: [assetID])
            markMessage = String(localized: "Marked for deletion. Nothing is deleted until you review.")
        } catch {
            onLimit()
        }
    }
}
