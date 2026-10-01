import Photos

/// Result of revalidating a pending selection right before deletion.
nonisolated struct DeletionPlan: Equatable, Sendable {
    /// Still present and deletable.
    var deletable: [String]
    /// No longer in the accessible library (deleted elsewhere, or access changed).
    var missing: [String]
    /// Present but Photos won't allow deleting them (e.g. shared/synced content).
    var notAllowed: [String]

    var isEmpty: Bool { deletable.isEmpty }

    /// Pure planning step, tested without PhotoKit.
    static func make(requested: [String], present: [String: Bool]) -> DeletionPlan {
        var seen = Set<String>()
        var plan = DeletionPlan(deletable: [], missing: [], notAllowed: [])
        for id in requested where seen.insert(id).inserted {
            switch present[id] {
            case .none: plan.missing.append(id)
            case .some(true): plan.deletable.append(id)
            case .some(false): plan.notAllowed.append(id)
            }
        }
        return plan
    }
}

nonisolated enum DeletionOutcome: Equatable, Sendable {
    /// Photos confirmed the deletion. Items are in Photos' Recently Deleted.
    case deleted(count: Int, missing: Int)
    /// The user tapped "Don't Allow" in the system alert, or nothing was deletable. Selections are kept.
    case cancelled
    case failed(message: String)
}

final class DeletionService {
    private let library: PhotoLibrary

    init(library: PhotoLibrary) {
        self.library = library
    }

    func plan(for ids: [String]) -> DeletionPlan {
        let assets = library.assets(for: ids)
        var present: [String: Bool] = [:]
        for asset in assets { present[asset.localIdentifier] = asset.canPerform(.delete) }
        return DeletionPlan.make(requested: ids, present: present)
    }

    /// Re-fetches and validates, then asks PhotoKit (which shows its own confirmation).
    /// Success is reported only after Photos reports success.
    func delete(ids: [String]) async -> (DeletionOutcome, DeletionPlan) {
        let plan = plan(for: ids)
        guard !plan.deletable.isEmpty else { return (.cancelled, plan) }
        let assets = library.assets(for: plan.deletable)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            return (.deleted(count: assets.count, missing: plan.missing.count), plan)
        } catch let error as NSError {
            // PHPhotosError.userCancelled (3072) when the user declines the system alert.
            if error.domain == PHPhotosErrorDomain, error.code == PHPhotosError.Code.userCancelled.rawValue {
                return (.cancelled, plan)
            }
            return (.failed(message: error.localizedDescription), plan)
        }
    }
}
