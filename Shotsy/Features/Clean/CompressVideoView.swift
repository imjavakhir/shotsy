import AVKit
import Photos
import SwiftUI

/// Local compression: inspect → choose option → export → validate → preview → save a new copy.
/// The original is kept. Only after a successful save can the user send the original to review.
struct CompressVideoView: View {
    let assetID: String

    @Environment(CompressionStore.self) private var compression
    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var reviews
    @Environment(PurchaseStore.self) private var purchases
    @Environment(Router.self) private var router
    @State private var preset: CompressionPreset = .hevc1080
    @State private var player: AVPlayer?
    @State private var reviewMessage: String?

    var body: some View {
        List {
            if let asset = library.asset(for: assetID) {
                Section {
                    HStack(spacing: Space.s) {
                        AssetThumbnail(asset: asset, targetSide: 100)
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Original").font(.appHeadline)
                            Text(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "")
                                .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                        }
                    }
                }
                stateSections(asset: asset)
            } else {
                Text("This video is no longer available.")
            }
        }
        .softAppBar()
        .navigationTitle("Compress Video")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: assetID) {
            if compression.sourceAssetID != assetID, let asset = library.asset(for: assetID) {
                compression.load(asset)
            }
        }
        .onDisappear {
            if case .saving = compression.state { return }
            if case .exporting = compression.state { return }
            player?.pause()
        }
    }

    @ViewBuilder
    private func stateSections(asset: PHAsset) -> some View {
        switch compression.state {
        case .idle:
            ProgressView()
        case .loadingSource(let progress):
            Section {
                ProgressView(value: progress) { Text(progress > 0 ? "Downloading from iCloud" : "Loading video") }
            }
        case .ready(let info):
            infoSection(info)
            optionsSection(info)
        case .exporting(let progress):
            Section {
                ProgressView(value: progress) { Text("Compressing… \(Int(progress * 100))%") }
                Button("Cancel", role: .cancel) { compression.cancel() }
            } footer: {
                Text("Keep Shotsy open. iOS may pause exports in the background.")
            }
        case .validating:
            Section { ProgressView { Text("Checking the compressed copy") } }
        case .preview(let url, let bytes, let verdict):
            previewSection(url: url, bytes: bytes, verdict: verdict)
        case .saving:
            Section { ProgressView { Text("Saving copy to Photos") } }
        case .saved(_, let saving):
            Section {
                Label("Compressed copy saved to Photos", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.appSuccess)
                if let saving {
                    Text("The copy is \(ByteCountFormatter.string(fromByteCount: saving, countStyle: .file)) smaller. Space is only freed if you delete the original and Recently Deleted is emptied.")
                        .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                }
                Button("Review original for deletion") {
                    do {
                        try reviews.decide(.marked, ids: [assetID])
                        reviewMessage = String(localized: "Original added to Review deletions. It's not deleted until you confirm there.")
                    } catch {
                        router.showPaywall(.dailyLimit)
                    }
                }
                .disabled(reviews.decision(for: assetID) == .marked)
                if let reviewMessage { Text(reviewMessage).font(.appFootnote).foregroundStyle(Color.appSecondaryText) }
            }
        case .failed(let message):
            Section {
                Notice(kind: .error, text: LocalizedStringKey(message))
                Button("Try again") { compression.load(asset) }
            } footer: {
                Text("Your original video wasn't changed.")
            }
        }
    }

    private func infoSection(_ info: VideoSourceInfo) -> some View {
        Section("Source") {
            LabeledContent("Duration", value: AssetDescription.duration(info.duration))
            LabeledContent("Resolution", value: "\(Int(info.size.width))×\(Int(info.size.height))")
            LabeledContent("Frame rate", value: "\(Int(info.frameRate.rounded())) fps")
            LabeledContent("Size", value: info.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                           ?? String(localized: "Unknown"))
            if info.isHDR { LabeledContent("Dynamic range", value: "HDR") }
            if info.isSlowMotion { LabeledContent("Type", value: String(localized: "Slow motion")) }
            if info.isCinematic { LabeledContent("Type", value: String(localized: "Cinematic")) }
            if info.isSpatial { LabeledContent("Type", value: String(localized: "Spatial")) }
            LabeledContent("Audio", value: info.hasAudio ? String(localized: "Yes") : String(localized: "No"))
        }
    }

    @ViewBuilder
    private func optionsSection(_ info: VideoSourceInfo) -> some View {
        Section {
            ForEach(CompressionPreset.allCases) { p in
                let availability = CompressionPolicy.availability(of: p, for: info)
                Button {
                    preset = p
                    Task { await compression.estimate(p) }
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: preset == p ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Color.appAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).foregroundStyle(Color.appText)
                            switch availability {
                            case .available(let notes):
                                ForEach(notes, id: \.self) { Text($0).font(.appFootnote).foregroundStyle(.orange) }
                            case .unavailable(let reason):
                                Text(reason).font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                            }
                        }
                    }
                }
                .disabled({ if case .unavailable = availability { true } else { false } }())
            }
            if let estimate = compression.estimatedBytes {
                LabeledContent("Estimated size", value: "≈ " + ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file))
            }
        } header: {
            Text("Quality")
        } footer: {
            Text("Compression is lossy: the copy won't be identical to the original. Orientation, audio, date and location are kept.")
        }
        Section {
            Button {
                guard purchases.isPro else { router.showPaywall(.compression); return }
                compression.start(preset)
            } label: {
                Label(purchases.isPro ? "Make compressed copy" : "Make compressed copy (Pro)",
                      systemImage: purchases.isPro ? "arrow.down.right.and.arrow.up.left" : "lock")
            }
        } footer: {
            Text("You'll preview the copy before anything is saved. The original is never replaced.")
        }
        .task(id: preset) { await compression.estimate(preset) }
    }

    @ViewBuilder
    private func previewSection(url: URL, bytes: Int64, verdict: CompressionPolicy.Verdict) -> some View {
        Section("Preview") {
            VideoPlayer(player: player)
                .frame(height: 260)
                .onAppear { player = AVPlayer(url: url) }
            LabeledContent("Compressed size (measured)", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            switch verdict {
            case .smaller(let saving):
                LabeledContent("Smaller by", value: ByteCountFormatter.string(fromByteCount: saving, countStyle: .file))
                Button("Save copy to Photos") { player?.pause(); compression.saveCopy() }
                    .buttonStyle(.primary)
            case .notSmaller:
                Notice(kind: .warning, text: "The copy isn't smaller than the original, so it won't be saved. Try a smaller option.")
            }
            Button("Discard", role: .destructive) { player?.pause(); compression.cancel() }
        }
    }
}
