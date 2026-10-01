import Photos

/// Library-wide reads for screens, kept off the main thread. PHFetchResult and PHAsset are safe to read from any
/// thread; results come back as plain values (identifiers, counts).
nonisolated enum BackgroundFetch {
    /// Runs `work` on a background thread (user-initiated priority by default). Cancelling the caller cancels
    /// the background task too, so work that checks `Task.isCancelled` can stop early.
    static func run<T: Sendable>(priority: TaskPriority = .userInitiated,
                                 _ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(priority: priority, operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Assets for identifiers, keyed by identifier; missing ones are left out. Call off the main thread and
    /// check access on the main actor first.
    static func assets(for ids: [String]) -> [String: PHAsset] {
        guard !ids.isEmpty else { return [:] }
        var map: [String: PHAsset] = [:]
        map.reserveCapacity(ids.count)
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { a, _, _ in map[a.localIdentifier] = a }
        return map
    }

    /// Same as `PhotoLibrary.fetch(_:ascending:)` without the access check; callers check access on the main actor.
    static func fetch(_ filter: MediaFilter, ascending: Bool = false) -> PHFetchResult<PHAsset> {
        PHAsset.fetchAssets(with: PhotoLibrary.options(predicate: PhotoLibrary.predicate(for: filter), ascending: ascending))
    }

    static func identifiers(in result: PHFetchResult<PHAsset>) -> [String] {
        var ids: [String] = []
        ids.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in ids.append(a.localIdentifier) }
        return ids
    }

    /// Call first in a `.task(id:)` that reloads on `PhotoLibrary.changeCount`. When only the library changed since
    /// the last load, waits briefly so a burst of change notifications (iCloud sync) rebuilds the screen once.
    /// The first load and user-driven changes (filters, search) run right away. Returns false if the task was
    /// cancelled while waiting, so it does no work.
    static func settle(changeCount: Int, loadedChangeCount: Int?) async -> Bool {
        guard let loadedChangeCount, loadedChangeCount != changeCount else { return !Task.isCancelled }
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return false }
        return true
    }
}
