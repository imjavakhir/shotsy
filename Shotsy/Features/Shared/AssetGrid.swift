import Photos
import SwiftUI

/// Grid cell with media badges. Selection and review state are drawn as overlays.
struct AssetCell: View {
    @Environment(PhotoLibrary.self) private var library
    let asset: PHAsset
    var isSelected = false
    var selectionMode = false
    var decision: ReviewDecision?
    var side: CGFloat = 130

    var body: some View {
        SquareThumbnail(asset: asset, targetSide: side)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    if asset.mediaType == .video {
                        Text(AssetDescription.duration(asset.duration))
                            .font(.appCaption)
                            .monospacedDigit()
                    }
                    if library.isFavorite(asset) {
                        Image(systemName: "heart.fill").font(.caption2)
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .padding(5)
                .accessibilityHidden(true)
            }
            .overlay(alignment: .topTrailing) {
                if selectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.appAccentFill : .black.opacity(0.25))
                        .padding(5)
                        .accessibilityHidden(true)
                } else if decision == .marked {
                    Image(systemName: "trash.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.appDanger)
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if isSelected { Rectangle().stroke(Color.appAccentFill, lineWidth: 3) }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AssetDescription.label(for: asset))
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if library.isFavorite(asset) { parts.append(String(localized: "Favorite")) }
        if decision == .marked { parts.append(String(localized: "Marked for deletion")) }
        return parts.joined(separator: ", ")
    }
}

enum GridMetrics {
    static func columns(for width: CGFloat, dynamicType: DynamicTypeSize) -> [GridItem] {
        let base: CGFloat = dynamicType.isAccessibilitySize ? 150 : 100
        let count = max(2, Int(width / base))
        return Array(repeating: GridItem(.flexible(), spacing: 2), count: count)
    }
}

/// Selectable grid over a list of identifiers (categories, albums, collections).
struct AssetIDGrid: View {
    let ids: [String]
    @Binding var selection: Set<String>
    var selectionMode: Bool
    var onOpen: (String) -> Void

    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var reviews
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var assets: [String: PHAsset] = [:]
    @State private var loadedChange: Int?

    var body: some View {
        GeometryReader { geo in
            let columns = GridMetrics.columns(for: geo.size.width, dynamicType: dynamicType)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(ids, id: \.self) { id in
                        if let asset = assets[id] {
                            AssetCell(asset: asset, isSelected: selection.contains(id), selectionMode: selectionMode,
                                      decision: reviews.decision(for: id))
                                .onTapGesture {
                                    if selectionMode { toggle(id) } else { onOpen(id) }
                                }
                        }
                    }
                }
                .padding(.bottom, 80)
            }
            .softAppBar()
        }
        .task(id: LoadKey(ids: ids, changeCount: library.changeCount)) { await load() }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    nonisolated private struct LoadKey: Equatable {
        var ids: [String]
        var changeCount: Int
    }

    private func load() async {
        guard await BackgroundFetch.settle(changeCount: library.changeCount, loadedChangeCount: loadedChange) else { return }
        let change = library.changeCount
        let ids = ids
        let canRead = library.access.canRead
        let map = await BackgroundFetch.run { () -> [String: PHAsset] in
            guard canRead, !ids.isEmpty else { return [:] }
            var map: [String: PHAsset] = [:]
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { a, _, _ in map[a.localIdentifier] = a }
            return map
        }
        guard !Task.isCancelled else { return }
        assets = map
        loadedChange = change
    }
}

/// Wraps a list of IDs for full-screen preview navigation.
struct PreviewRequest: Identifiable, Hashable {
    let ids: [String]
    let start: String
    var id: String { start }
}
