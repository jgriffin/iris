import Foundation
import Observation
import os

// Thin wrapper over `RecentBookmarks` (M13·P1) — the third instance, and the
// forcing function for factoring the shared generic. All MRU machinery lives
// in the base; see `RecentBookmarks.swift` for the full design + test-deferral
// rationale. This subclass supplies only the storage key, MRU cap, and logger
// category for recently-opened **folder** URLs.
//
// A directory bookmark resolves exactly like a file bookmark, and
// `FileManager.fileExists(atPath:)` returns `true` for directories, so the
// base's `resolve()` validation passes for folders unchanged — no special
// casing here. Not yet wired into the shell (that's M13·P2); it compiles as
// part of the demo target via `Apps/project.yml`'s recursive glob over
// `Apps/Shared/`.

/// `UserDefaults`-backed MRU list of recently-opened **folder** URLs for the
/// Iris demos — the folder sibling of [`RecentVideos`](./RecentVideos.swift)
/// and [`RecentImages`](./RecentImages.swift). One folder bookmark covers its
/// children (the existing `user-selected.read-only` entitlement suffices). See
/// [`RecentBookmarks`](./RecentBookmarks.swift) for the storage shape, platform
/// gating, and concurrency notes.
@MainActor
final class RecentFolders: RecentBookmarks {
    /// Default storage key. `.v1` lets future schema bumps migrate cleanly
    /// without clobbering an existing user's MRU.
    static let defaultKey = "iris.recent.folders.v1"

    /// - Parameters:
    ///   - defaults: `UserDefaults` instance to read/write. Override for tests.
    ///   - key: storage key. Override for tests or future schema bumps.
    ///   - limit: max entries retained.
    init(
        defaults: UserDefaults = .standard,
        key: String = RecentFolders.defaultKey,
        limit: Int = RecentBookmarks.defaultLimit
    ) {
        super.init(
            defaults: defaults,
            key: key,
            limit: limit,
            logger: Logger(subsystem: "iris.demo", category: "recent-folders")
        )
    }
}
