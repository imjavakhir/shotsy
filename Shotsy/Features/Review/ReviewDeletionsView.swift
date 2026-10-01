import Photos
import SwiftUI

/// Pending deletion queue → explicit, revalidated PhotoKit deletion with the system confirmation.
struct ReviewDeletionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ReviewStore.self) private var reviews
    @Environment(PhotoLibrary.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicType

    @State private var selection = Set<String>()
    @State private var initialized = false
    @State private var working = false
    @State private var result: DeletionOutcome?
    @State private var deletedCount = 0
    @State private var preview: PreviewRequest?
    @State private var confirmUnmarkAll = false

    var body: some View {
        let pending = reviews.pendingIDs
        let assets = library.assets(for: pending)
        Group {
            if case .deleted(let count, let missing)? = result {
                DeletedView(count: count, missing: missing, stillMarked: pending.count,
                            unmarkRest: { reviews.unmark(pending) }, done: { dismiss() })
            } else if pending.isEmpty {
                MascotMessage(animated: .idle, title: "Nothing to review",
                              message: "When you mark photos for deletion, they wait here until you confirm.")
            } else {
                content(assets: assets)
            }
        }
        .pageBackground()
        .navigationTitle("Review deletions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            if !pending.isEmpty, result == nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button(selection.count == assets.count ? LocalizedStringKey("Deselect All") : LocalizedStringKey("Select All"),
                               systemImage: selection.count == assets.count ? "circle" : "checkmark.circle") {
                            selection = selection.count == assets.count ? [] : Set(assets.map(\.localIdentifier))
                        }
                        Button("Unmark All", systemImage: "arrow.uturn.backward") { confirmUnmarkAll = true }
                    }
                }
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            // Favorites start unselected when protection is on; everything else starts selected.
            selection = Set(assets.filter { !(settings.protectFavorites && library.isFavorite($0)) }.map(\.localIdentifier))
        }
        .onChange(of: reviews.revision) {
            selection.formIntersection(Set(reviews.pendingIDs))
        }
        .fullScreenCover(item: $preview) { AssetPreviewView(request: $0) }
        .confirmationDialog("Unmark all photos?", isPresented: $confirmUnmarkAll, titleVisibility: .visible) {
            Button("Unmark All") { reviews.unmark(pending) }
        } message: {
            Text("They stay in your library and leave the deletion queue.")
        }
    }

    @ViewBuilder
    private func content(assets: [PHAsset]) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Tap to deselect anything you want to keep. Deselected items stay in the queue.")
                            .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                        if settings.protectFavorites, assets.contains(where: library.isFavorite) {
                            Notice(kind: .info, text: "Favorites start unselected. Tap one to include it.")
                        }
                        if case .cancelled? = result {
                            Notice(kind: .info, text: "Nothing was deleted. Your selections are saved.")
                        }
                        if case .failed(let message)? = result {
                            Notice(kind: .error, text: "Photos couldn't delete these: \(message). Nothing was removed.")
                        }
                        LazyVGrid(columns: GridMetrics.columns(for: geo.size.width - 2 * Space.page, dynamicType: dynamicType), spacing: 2) {
                            ForEach(assets, id: \.localIdentifier) { asset in
                                let id = asset.localIdentifier
                                AssetCell(asset: asset, isSelected: selection.contains(id), selectionMode: true)
                                    .onTapGesture { toggle(id) }
                                    .contextMenu {
                                        Button("Preview", systemImage: "eye") {
                                            preview = PreviewRequest(ids: assets.map(\.localIdentifier), start: id)
                                        }
                                        Button("Keep instead", systemImage: "arrow.uturn.backward") {
                                            reviews.unmark([id])
                                        }
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, Space.page)
                    .padding(.vertical, Space.s)
                }
                .softAppBar()
            }

            VStack(spacing: Space.xs) {
                let unselected = assets.map(\.localIdentifier).filter { !selection.contains($0) }
                if !unselected.isEmpty {
                    Button("Unmark \(unselected.count) unselected") { reviews.unmark(unselected) }
                        .buttonStyle(.secondary)
                        .disabled(working)
                }
                Button {
                    Task { await delete() }
                } label: {
                    if working {
                        ProgressView().tint(.white)
                    } else {
                        Text("Delete \(selection.count) items")
                    }
                }
                .buttonStyle(.destructivePrimary)
                .disabled(selection.isEmpty || working)
                Text("Deleted items move to Recently Deleted in Photos, where you can recover them for about 30 days. With iCloud Photos on, they're removed from your other devices too.")
                    .font(.appCaption)
                    .foregroundStyle(Color.appSecondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Space.page)
            .padding(.vertical, Space.s)
            .background(.bar)
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func delete() async {
        working = true
        defer { working = false }
        let requested = Array(selection)
        let (outcome, plan) = await model.deletion.delete(ids: requested)
        // Items that no longer exist are dropped from the queue either way.
        if !plan.missing.isEmpty { reviews.forget(Set(plan.missing)) }
        if case .deleted(let count, _) = outcome {
            reviews.forget(Set(plan.deletable))
            settings.totalDeleted += count
            selection.removeAll()
        }
        withAnimation { result = outcome }
    }
}

/// Tidy moment, only after Photos confirmed the deletion.
private struct DeletedView: View {
    let count: Int
    let missing: Int
    /// Items the user left unselected: still marked, so they're offered a choice instead of a silent queue.
    let stillMarked: Int
    let unmarkRest: () -> Void
    let done: () -> Void
    @Environment(SettingsStore.self) private var settings
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                ShotsyAnimation(clip: .tidy).frame(width: 180, height: 180).padding(.top, Space.xxl)
                Text("All tidy").font(.display(28, relativeTo: .title)).foregroundStyle(Color.appText)
                Text("Deleted \(count) items. They're in Recently Deleted in Photos for about 30 days if you change your mind.")
                    .font(.appBody).foregroundStyle(Color.appSecondaryText).multilineTextAlignment(.center)
                if missing > 0 {
                    Text("\(missing) items were already gone, so they were removed from the queue.")
                        .font(.appFootnote).foregroundStyle(Color.appSecondaryText).multilineTextAlignment(.center)
                }
                Text("Storage frees up once Recently Deleted is emptied. With iCloud Photos, it can take a while to update.")
                    .font(.appFootnote).foregroundStyle(Color.appSecondaryText).multilineTextAlignment(.center)
                if stillMarked > 0 {
                    Notice(kind: .info, text: "\(stillMarked) photos you skipped are still marked for deletion.")
                    Button("Unmark Them", action: unmarkRest).buttonStyle(.secondary)
                }
                Button(stillMarked > 0 ? LocalizedStringKey("Keep Marked") : LocalizedStringKey("Done"), action: done).buttonStyle(.primary)
            }
            .padding(.horizontal, Space.xl)
        }
        .sensoryFeedback(.success, trigger: appeared) { _, _ in settings.hapticsEnabled }
        .onAppear { appeared = true }
    }
}
