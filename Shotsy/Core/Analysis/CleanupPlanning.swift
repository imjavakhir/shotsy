import Foundation
import Photos

// MARK: - Bursts

/// One photo of a burst, read from PhotoKit (`includeAllBurstAssets`).
nonisolated struct BurstMember: Sendable, Equatable {
    var id: String
    var burstID: String
    var isUserPick: Bool
    var isAutoPick: Bool
    var representsBurst: Bool
    var isFavorite: Bool
    var date: Date?
    var pixelCount: Int
}

/// A burst with the shot to keep and the rest suggested for marking.
nonisolated struct BurstGroup: Sendable, Identifiable, Equatable {
    /// The burst identifier.
    var id: String
    /// Members in capture order.
    var ids: [String]
    var keeper: String
    /// Suggested for marking: not the keeper, not a user pick, not a protected favorite.
    var extras: [String]
    var date: Date?

    /// Extras when the user keeps `keeper` instead. The suggested keeper becomes an extra; user picks and
    /// protected favorites stay out.
    func extras(keeping keeper: String) -> [String] {
        ids.filter { $0 != keeper && ($0 == self.keeper || extras.contains($0)) }
    }
}

nonisolated enum BurstPlanner {
    /// Best shot: the user's pick, then the one Photos picked, then the burst's representative, then the first.
    static func keeper(of members: [BurstMember]) -> String? {
        (members.first(where: \.isUserPick) ?? members.first(where: \.isAutoPick)
            ?? members.first(where: \.representsBurst) ?? members.first)?.id
    }

    /// Groups members by burst, newest burst first. Bursts with nothing to suggest are left out.
    static func groups(_ members: [BurstMember], protectFavorites: Bool) -> [BurstGroup] {
        var order: [String] = []
        var byBurst: [String: [(offset: Int, member: BurstMember)]] = [:]
        for (i, m) in members.enumerated() {
            if byBurst[m.burstID] == nil { order.append(m.burstID) }
            byBurst[m.burstID, default: []].append((i, m))
        }
        let groups: [BurstGroup] = order.compactMap { burstID in
            let sorted = (byBurst[burstID] ?? []).sorted {
                let a = $0.member.date ?? .distantPast, b = $1.member.date ?? .distantPast
                return a == b ? $0.offset < $1.offset : a < b
            }.map(\.member)
            guard sorted.count > 1, let keeper = keeper(of: sorted) else { return nil }
            let extras = sorted.filter { m in
                m.id != keeper && !m.isUserPick && !(protectFavorites && m.isFavorite)
            }.map(\.id)
            guard !extras.isEmpty else { return nil }
            return BurstGroup(id: burstID, ids: sorted.map(\.id), keeper: keeper, extras: extras, date: sorted.first?.date)
        }
        return groups.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

// MARK: - Months

/// A month with photos or videos still to sort.
nonisolated struct MonthProgress: Identifiable, Sendable, Equatable {
    var section: MonthSection
    /// Every item of the month, newest first.
    var ids: [String]
    var unsorted: Int
    /// The month's first unsorted items, for the card.
    var previewIDs: [String]

    var id: String { section.key }
    var total: Int { ids.count }
}

/// The library grouped into months, newest first. Reading it is the PhotoKit and calendar part; it's reused
/// while only review decisions change, which then just re-filter it (`MonthPlanner.unsorted`).
nonisolated struct MonthSnapshot: Sendable {
    /// Every month with its items; `unsorted` and `previewIDs` are left empty.
    var months: [MonthProgress] = []

    /// Stops early (returning a partial snapshot) if the task is cancelled; callers drop cancelled results.
    static func read(_ result: PHFetchResult<PHAsset>, calendar: Calendar = .current) -> MonthSnapshot {
        var ids: [String] = []
        var dates: [Date?] = []
        ids.reserveCapacity(result.count)
        dates.reserveCapacity(result.count)
        result.enumerateObjects { a, i, stop in
            if i % 4096 == 0, Task.isCancelled { stop.pointee = true; return }
            ids.append(a.localIdentifier)
            dates.append(a.creationDate)
        }
        return MonthSnapshot(months: MonthPlanner.group(ids: ids, dates: dates, calendar: calendar))
    }
}

nonisolated enum MonthPlanner {
    /// Months that still have unreviewed items, newest first. `ids` and `dates` are parallel and sorted newest first.
    static func unsortedMonths(ids: [String], dates: [Date?], decisions: [String: ReviewDecision],
                               previewCount: Int = 4, calendar: Calendar = .current) -> [MonthProgress] {
        unsorted(group(ids: ids, dates: dates, calendar: calendar), decisions: decisions, previewCount: previewCount)
    }

    /// Every month with its items, newest first, with `unsorted` and `previewIDs` empty.
    /// `ids` and `dates` are parallel and sorted newest first.
    static func group(ids: [String], dates: [Date?], calendar: Calendar = .current) -> [MonthProgress] {
        guard ids.count == dates.count else { return [] }
        var result: [MonthProgress] = []
        var index: [String: Int] = [:]
        for section in LibraryIndex.months(dates: dates, calendar: calendar) {
            let members = Array(ids[section.range])
            // A month split by out-of-order dates (rare) is merged into its first appearance.
            if let i = index[section.key] {
                result[i].ids += members
            } else {
                index[section.key] = result.count
                result.append(MonthProgress(section: section, ids: members, unsorted: 0, previewIDs: []))
            }
        }
        return result
    }

    /// The months of `grouped` that still have unreviewed items, with their counts and previews.
    static func unsorted(_ grouped: [MonthProgress], decisions: [String: ReviewDecision],
                         previewCount: Int = 4) -> [MonthProgress] {
        var result: [MonthProgress] = []
        for var month in grouped {
            if Task.isCancelled { break }
            var unsorted = 0
            var preview: [String] = []
            for id in month.ids where decisions[id] == nil {
                unsorted += 1
                if preview.count < previewCount { preview.append(id) }
            }
            guard unsorted > 0 else { continue }
            month.unsorted = unsorted
            month.previewIDs = preview
            result.append(month)
        }
        return result
    }
}

// MARK: - Storage estimate

/// "Free up about X" on the Clean tab: measured bytes for local videos plus an estimate for photos.
/// Never shown as exact.
nonisolated enum StorageEstimate {
    /// Rough bytes per pixel for a camera photo. A 12 MP HEIC is usually 1.5–4 MB, so ~0.25 B/px is a middle
    /// value (JPEG runs higher, so this tends to underestimate). Only ever shown as "about".
    static let photoBytesPerPixel = 0.25
    /// The Large Videos list ranks every video; only ones at least this big count toward the estimate.
    static let largeVideoBytes: Int64 = 100_000_000

    struct Result: Sendable, Equatable {
        var measuredVideoBytes: Int64 = 0
        var estimatedPhotoBytes: Int64 = 0
        /// Candidate videos with no local file to measure (iCloud only); not counted.
        var unmeasuredVideos = 0

        var total: Int64 { measuredVideoBytes + estimatedPhotoBytes }
    }

    static func photoBytes(pixels: Int) -> Int64 {
        Int64((Double(max(0, pixels)) * photoBytesPerPixel).rounded())
    }

    /// - Parameters:
    ///   - photoPixels: pixel counts of photos the cleanup categories suggest removing.
    ///   - largeVideos: all videos; only measured ones over `largeVideoBytes` count.
    ///   - otherVideos: screen recordings and slo-mo; every measured one counts.
    ///   - excluded: already-marked items (they're in Review deletions, not here).
    static func compute(photoPixels: [String: Int], largeVideos: [VideoItem], otherVideos: [VideoItem],
                        excluded: Set<String>, favorites: Set<String>, protectFavorites: Bool) -> Result {
        func skip(_ id: String) -> Bool { excluded.contains(id) || (protectFavorites && favorites.contains(id)) }
        var result = Result()
        var seen = Set<String>()
        for video in largeVideos where !skip(video.id) {
            guard let bytes = video.bytes, bytes >= largeVideoBytes, seen.insert(video.id).inserted else { continue }
            result.measuredVideoBytes += bytes
        }
        for video in otherVideos where !skip(video.id) && seen.insert(video.id).inserted {
            if let bytes = video.bytes { result.measuredVideoBytes += bytes } else { result.unmeasuredVideos += 1 }
        }
        for (id, pixels) in photoPixels where !skip(id) && seen.insert(id).inserted {
            result.estimatedPhotoBytes += photoBytes(pixels: pixels)
        }
        return result
    }
}
