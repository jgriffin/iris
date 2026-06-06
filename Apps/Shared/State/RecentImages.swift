import Foundation
import Observation
import os

// Thin wrapper over `RecentBookmarks` (M13·P1). All MRU machinery —
// `[Data]` bookmark persistence, per-platform security-scope flags,
// `addOrPromote` dedup-by-path, stale-refresh `resolve()`, `clear()` — lives
// in the base; see `RecentBookmarks.swift` for the full design + test-deferral
// rationale. This subclass supplies only the storage key, MRU cap, and logger
// category for recently-opened **still-image** URLs. Public API and the
// `iris.recent.images.v1` defaults key are unchanged (no migration). Reverses
// M8·P4's "deliberate siblings" — the base is the shared generic those notes
// anticipated.

/// `UserDefaults`-backed MRU list of recently-opened **still-image** URLs for
/// the Iris demos — the image-page sibling of
/// [`RecentVideos`](./RecentVideos.swift). See
/// [`RecentBookmarks`](./RecentBookmarks.swift) for the storage shape, platform
/// gating, and concurrency notes.
@MainActor
final class RecentImages: RecentBookmarks {
    /// Default storage key. `.v1` lets future schema bumps migrate cleanly
    /// without clobbering an existing user's MRU.
    static let defaultKey = "iris.recent.images.v1"

    /// - Parameters:
    ///   - defaults: `UserDefaults` instance to read/write. Override for tests.
    ///   - key: storage key. Override for tests or future schema bumps.
    ///   - limit: max entries retained.
    init(
        defaults: UserDefaults = .standard,
        key: String = RecentImages.defaultKey,
        limit: Int = RecentBookmarks.defaultLimit
    ) {
        super.init(
            defaults: defaults,
            key: key,
            limit: limit,
            logger: Logger(subsystem: "iris.demo", category: "recent-images")
        )
    }
}
