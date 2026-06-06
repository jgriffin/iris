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
// casing here.
//
// **Per-mode, not shared (M13 smoke round 1).** Smoke testing showed a folder
// picked via the Image flow appearing under *both* modes' FOLDERS — wrong: a
// folder of clips and a folder of stills are different folders in practice. So
// folders get TWO MRUs, one per mode, via the `.video()` / `.image()` factories
// below (distinct keys + logger categories). The earlier shared key
// `iris.recent.folders.v1` is abandoned WITHOUT migration — it was branch-only
// state from smoke testing and never shipped on `main`.

/// `UserDefaults`-backed MRU list of recently-opened **folder** URLs for the
/// Iris demos — the folder sibling of [`RecentVideos`](./RecentVideos.swift)
/// and [`RecentImages`](./RecentImages.swift). One folder bookmark covers its
/// children (the existing `user-selected.read-only` entitlement suffices). See
/// [`RecentBookmarks`](./RecentBookmarks.swift) for the storage shape, platform
/// gating, and concurrency notes.
///
/// **One type, two instances.** Unlike `RecentVideos` / `RecentImages` (which
/// fix their key + category), folders are per-mode but otherwise identical, so a
/// single parameterized type with `.video()` / `.image()` factories is the
/// cleaner shape than two near-identical thin subclasses. The factories supply
/// the distinct storage keys + logger categories.
@MainActor
final class RecentFolders: RecentBookmarks {
    /// The Playback (movie-folder) MRU. Key/category distinct from the image
    /// instance so a folder picked for clips never leaks into the Image mode.
    static func video(
        defaults: UserDefaults = .standard,
        limit: Int = RecentBookmarks.defaultLimit
    ) -> RecentFolders {
        RecentFolders(
            defaults: defaults,
            key: "iris.recent.video-folders.v1",
            category: "recent-video-folders",
            limit: limit
        )
    }

    /// The Image (still-folder) MRU. Sibling of `video()`.
    static func image(
        defaults: UserDefaults = .standard,
        limit: Int = RecentBookmarks.defaultLimit
    ) -> RecentFolders {
        RecentFolders(
            defaults: defaults,
            key: "iris.recent.image-folders.v1",
            category: "recent-image-folders",
            limit: limit
        )
    }

    /// - Parameters:
    ///   - defaults: `UserDefaults` instance to read/write. Override for tests.
    ///   - key: storage key (per-mode; see `video()` / `image()`).
    ///   - category: logger category for this MRU's diagnostics.
    ///   - limit: max entries retained.
    init(
        defaults: UserDefaults = .standard,
        key: String,
        category: String,
        limit: Int = RecentBookmarks.defaultLimit
    ) {
        super.init(
            defaults: defaults,
            key: key,
            limit: limit,
            logger: Logger(subsystem: "iris.demo", category: category)
        )
    }
}
