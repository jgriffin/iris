import Foundation
import Observation
import os

// MARK: - Test deferral note
//
// Same deferral as `RecentVideos`: this file lives under `Apps/Shared/`,
// which is consumed by the demo Xcode targets via `Apps/project.yml` and is
// NOT reachable from any SwiftPM test target. Behavior is fully observable
// through the image-page UI (every promote / resolve / stale-bookmark drop is
// visible the moment the picker or the recents list runs); resolve failures
// are logged via `iris.demo`. If a regression here ever bites twice, revisit
// by extracting shared demo support into a SwiftPM target the library doesn't
// depend on.

/// `UserDefaults`-backed MRU list of recently-opened **still-image** URLs for
/// the Iris demos — the image-page sibling of
/// [`RecentVideos`](./RecentVideos.swift).
///
/// **Deliberate sibling, not a generic base.** This mirrors `RecentVideos`'s
/// shape (bookmark-backed `[Data]`, per-platform security-scope flags, same
/// public API) on purpose. Factoring a shared generic base across the two is
/// separately backlogged; until then the duplication keeps each model's
/// platform gating obvious and independently auditable.
///
/// Storage is a `[Data]` array of platform-appropriate bookmark blobs
/// serialized via `JSONEncoder` to a single key:
///
/// - On macOS, the demo target is sandboxed (`files.user-selected.read-only`)
///   and needs security-scoped bookmarks to re-open user picks across launches.
/// - On iOS, plain bookmarks (`[.minimalBookmark]`) survive within-sandbox
///   moves better than raw paths.
///
/// Concurrency: `@Observable` + `@MainActor`. All mutations happen from the UI
/// thread; `UserDefaults` is the single backing store and this model is the
/// single writer.
///
/// Persistence shape:
/// - Storage key: configurable (default `"iris.recent.images.v1"`). The `.v1`
///   suffix lets a future schema bump migrate without trashing existing MRUs.
/// - Encoded value: `Data` produced by `JSONEncoder().encode([Data])`, where
///   each inner `Data` is a bookmark blob.
@MainActor
@Observable
final class RecentImages {
    /// Default storage key. `.v1` lets future schema bumps migrate cleanly
    /// without clobbering an existing user's MRU.
    static let defaultKey = "iris.recent.images.v1"

    /// Default cap on stored entries — same ballpark as `RecentVideos`.
    static let defaultLimit = 10

    /// Resolved MRU display state — *raw bookmark blobs* in MRU order (latest
    /// first). Views observe this directly; URL resolution is done lazily via
    /// `resolve()` so the model doesn't hold a strong list of `URL`s with
    /// implicit security-scope semantics.
    private(set) var bookmarks: [Data] = []

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int

    /// - Parameters:
    ///   - defaults: `UserDefaults` instance to read/write. Override for tests.
    ///   - key: storage key. Override for tests or future schema bumps.
    ///   - limit: max entries retained. Older entries past the cap are dropped
    ///     on `addOrPromote`.
    init(
        defaults: UserDefaults = .standard,
        key: String = RecentImages.defaultKey,
        limit: Int = RecentImages.defaultLimit
    ) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
        self.bookmarks = Self.load(from: defaults, key: key)
    }

    // MARK: - Public API

    /// Add `url` to the MRU. If a matching bookmark already exists, move it to
    /// the front (no duplicates). Trims to `limit` entries.
    ///
    /// "Matching" is determined by resolving each existing bookmark and
    /// comparing the resolved URL's standardized file path to `url`'s. Bookmark
    /// resolution is best-effort; entries that fail to resolve at this step are
    /// dropped.
    ///
    /// Bookmark creation flags differ per platform:
    /// - macOS: `[.withSecurityScope, .securityScopeAllowOnlyReadAccess]` —
    ///   required for the sandbox entitlement `files.user-selected.read-only`.
    /// - iOS: `[.minimalBookmark]` — smaller and resolves more leniently across
    ///   within-sandbox moves than full bookmarks.
    func addOrPromote(_ url: URL) {
        let bookmarkData: Data
        do {
            bookmarkData = try Self.makeBookmark(for: url)
        } catch {
            Logger.recentImages.error(
                """
                addOrPromote: bookmark creation failed for \
                \(url.lastPathComponent, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """
            )
            return
        }

        var next: [Data] = [bookmarkData]
        let incomingPath = url.standardizedFileURL.path

        for existing in bookmarks {
            if let resolved = Self.tryResolve(existing),
                resolved.standardizedFileURL.path == incomingPath
            {
                continue
            }
            next.append(existing)
            if next.count >= limit { break }
        }

        bookmarks = Array(next.prefix(limit))
        persist()
    }

    /// Resolve bookmarks back to URLs in MRU order. Drops entries whose
    /// bookmarks fail to resolve, are stale beyond recovery, or point to files
    /// that no longer exist. If `bookmarkDataIsStale == true` but the URL still
    /// resolves to an existing file, refresh the bookmark in place and persist.
    ///
    /// On macOS the resolved URLs carry a *latent* security scope — callers
    /// must `startAccessingSecurityScopedResource()` / `stop…` around use. The
    /// model does not start the scope itself; that's the consumer view's
    /// responsibility (and it owns the matching stop).
    func resolve() -> [URL] {
        var refreshed = false
        var nextBookmarks: [Data] = []
        var resolved: [URL] = []

        for bookmark in bookmarks {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: Self.resolveOptions,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )

                let exists = FileManager.default.fileExists(atPath: url.path)
                guard exists else {
                    Logger.recentImages.warning(
                        "resolve: dropping missing \(url.lastPathComponent, privacy: .public)"
                    )
                    continue
                }

                if isStale {
                    // M9·P1·A5: a stale bookmark still resolved to an existing
                    // file — log it so a flaky / repeatedly-refreshing entry is
                    // diagnosable, then refresh the blob in place.
                    if let refreshedBlob = try? Self.makeBookmark(for: url) {
                        Logger.recentImages.notice(
                            "resolve: refreshed stale bookmark for \(url.lastPathComponent, privacy: .public)"
                        )
                        nextBookmarks.append(refreshedBlob)
                        refreshed = true
                    } else {
                        Logger.recentImages.warning(
                            "resolve: stale bookmark refresh FAILED for \(url.lastPathComponent, privacy: .public); keeping original blob"
                        )
                        nextBookmarks.append(bookmark)
                    }
                } else {
                    nextBookmarks.append(bookmark)
                }

                resolved.append(url)
            } catch {
                Logger.recentImages.warning(
                    "resolve: dropping unresolvable bookmark: \(String(describing: error), privacy: .public)"
                )
            }
        }

        if nextBookmarks.count != bookmarks.count || refreshed {
            bookmarks = nextBookmarks
            persist()
        }

        return resolved
    }

    /// Empty the MRU. Persists immediately.
    func clear() {
        bookmarks = []
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let blob = try JSONEncoder().encode(bookmarks)
            defaults.set(blob, forKey: key)
        } catch {
            Logger.recentImages.error(
                "persist: encode failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private static func load(from defaults: UserDefaults, key: String) -> [Data] {
        guard let blob = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([Data].self, from: blob)
        } catch {
            Logger.recentImages.error(
                "load: decode failed (resetting MRU): \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    // MARK: - Bookmark flag set (platform-gated)

    /// Best-effort resolve that swallows errors and stale-flagged URLs. Used by
    /// `addOrPromote` for dedup; never propagates errors.
    private static func tryResolve(_ data: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: resolveOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    #if os(macOS)
    private static let createOptions: URL.BookmarkCreationOptions = [
        .withSecurityScope,
        .securityScopeAllowOnlyReadAccess,
    ]
    private static let resolveOptions: URL.BookmarkResolutionOptions = [
        .withSecurityScope
    ]
    #else
    private static let createOptions: URL.BookmarkCreationOptions = [
        .minimalBookmark
    ]
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif

    private static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: createOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}

extension Logger {
    fileprivate static let recentImages = Logger(subsystem: "iris.demo", category: "recent-images")
}
