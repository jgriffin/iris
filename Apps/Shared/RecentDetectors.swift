import Foundation
import Iris
import Observation

/// `UserDefaults`-backed MRU list of recently-selected detector IDs for the
/// Iris demos. Models the same shape as `RecentVideos` but is far simpler:
/// a plain ordered `[String]` of catalog entry ids (e.g. `"vision.rectangles"`,
/// `"coreml.yolo26n"`), latest-selected first. No bookmarks, no security
/// scope — detector ids are stable strings owned by `DemoCatalog` /
/// `DetectorCatalog`.
///
/// **Why this exists.** The demos previously hardcoded `"vision.rectangles"`
/// as the launch detector, which is the wrong default for the real workflow
/// (the curator switches among *object* models). This store remembers the
/// last-used detectors and floats them to the top of the picker, so the most
/// recent choice is both the launch selection and the first picker row.
///
/// **MRU-sort over the live catalog.** `sortedEntries(_:)` orders a live
/// `DetectorCatalog`'s entries by MRU: known ids first (in MRU order), then
/// any remaining catalog entries in their natural catalog order. That keeps a
/// newly-bundled or newly-available detector visible (it just sorts after the
/// remembered ones) rather than hidden because it was never selected.
///
/// Concurrency: `@Observable` + `@MainActor`. All mutations happen from the
/// UI thread; `UserDefaults` is the single backing store and this model is the
/// single writer.
///
/// Persistence shape:
/// - Storage key: configurable (default `"iris.recent.detectors.v1"`). The
///   `.v1` suffix lets a future schema bump migrate without trashing the MRU.
/// - Encoded value: a plain `[String]` written directly to `UserDefaults`
///   (`stringArray(forKey:)` / `set(_:forKey:)`) — opaque-free, inspectable
///   via `defaults read`.
@MainActor
@Observable
final class RecentDetectors {
    /// Default storage key. `.v1` lets future schema bumps migrate cleanly.
    static let defaultKey = "iris.recent.detectors.v1"

    /// Default cap on stored entries. Detectors are few; 10 is plenty of
    /// headroom while still trimming a stale tail.
    static let defaultLimit = 10

    /// MRU-ordered detector ids, latest-selected first. Views read this to
    /// determine the launch selection; the picker reads `sortedEntries(_:)`.
    private(set) var ids: [String] = []

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int

    /// - Parameters:
    ///   - defaults: `UserDefaults` instance to read/write. Override for tests.
    ///   - key: storage key. Override for tests or future schema bumps.
    ///   - limit: max entries retained; older entries past the cap are dropped
    ///     on `addOrPromote`.
    init(
        defaults: UserDefaults = .standard,
        key: String = RecentDetectors.defaultKey,
        limit: Int = RecentDetectors.defaultLimit
    ) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
        self.ids = defaults.stringArray(forKey: key) ?? []
    }

    // MARK: - Public API

    /// Add `id` to the MRU, moving it to the front if already present (dedup,
    /// move-to-front). Trims to `limit` and persists.
    func addOrPromote(id: String) {
        var next = [id]
        next.append(contentsOf: ids.filter { $0 != id })
        ids = Array(next.prefix(limit))
        persist()
    }

    /// The most-recently-selected id that still exists in `catalog`, or `nil`
    /// if the MRU is empty or every remembered id is stale (no longer in the
    /// catalog). Callers fall back to the catalog's first entry when this is
    /// `nil` — preserving the prior first-entry default.
    func firstAvailable(in catalog: DetectorCatalog) -> String? {
        let live = Set(catalog.entries.map(\.id))
        return ids.first(where: live.contains)
    }

    /// `catalog`'s entries sorted by MRU: remembered ids first (in MRU order),
    /// then any remaining catalog entries in their natural catalog order. A
    /// newly-available detector (never selected) therefore still appears — it
    /// just sorts after the remembered ones.
    func sortedEntries(_ catalog: DetectorCatalog) -> [DetectorCatalogEntry] {
        let byID = Dictionary(
            catalog.entries.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        var ordered: [DetectorCatalogEntry] = []

        // Remembered ids first, in MRU order — only those still in the catalog.
        for id in ids {
            guard let entry = byID[id], !seen.contains(id) else { continue }
            ordered.append(entry)
            seen.insert(id)
        }
        // Then any remaining catalog entries in their natural order.
        for entry in catalog.entries where !seen.contains(entry.id) {
            ordered.append(entry)
            seen.insert(entry.id)
        }
        return ordered
    }

    // MARK: - Persistence

    private func persist() {
        defaults.set(ids, forKey: key)
    }
}
