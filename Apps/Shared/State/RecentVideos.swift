import Foundation
import Observation
import os

// MARK: - Test deferral note
//
// The demo-ergonomics Phase 1 brief specifies unit tests against a
// `UserDefaults` instance scoped to a test suite name. They're deferred
// intentionally: this file lives under `Apps/Shared/` (consumed by both
// demo Xcode targets via `Apps/project.yml`), which is *not* reachable
// from any SwiftPM test target. The library's `Tests/IrisTests/` target
// can only see code under `Sources/Iris/`, and moving `RecentVideos`
// into the library would pollute the Iris package surface with a
// consumer-app concern (`UserDefaults`, security-scoped bookmarks).
// That trade was rejected by Phase 1 — the exit criterion is
// `git diff Sources/Iris/` empty.
//
// The remaining option — a new SwiftPM test target for shared demo code
// — would require non-trivial `Package.swift` plumbing for a ~120-line
// model. Behavior is fully observable through Phase 2 + 3's UI: every
// MRU promote, resolve, and stale-bookmark drop is visible the moment
// the picker or the recents list runs. Resolve failures are logged via
// `iris.demo` so manual smoke surfaces them.
//
// If a regression here ever bites twice, revisit by extracting into a
// SwiftPM target like `IrisDemoSupport` that the library doesn't depend
// on (a `Package.swift` change, not a `Sources/Iris/` change).

/// `UserDefaults`-backed MRU list of recently-opened video URLs for the
/// Iris demos. Storage is a `[Data]` array of platform-appropriate
/// bookmark blobs serialized via `JSONEncoder` to a single key; raw URLs
/// are *not* stored because:
///
/// - On macOS, the demo target is sandboxed (`files.user-selected.read-only`)
///   and needs security-scoped bookmarks to re-open user picks across
///   launches at all.
/// - On iOS, plain bookmarks (`[.minimalBookmark]`) survive within-sandbox
///   moves better than raw paths.
///
/// Both demos use the same public API; only the bookmark flag set differs
/// per platform (see `addOrPromote` / `resolve`).
///
/// Concurrency: `@Observable` + `@MainActor`. All mutations happen from
/// the UI thread so observation publishes order with `UserDefaults`
/// writes. `UserDefaults` itself is thread-safe but the model is the
/// single writer.
///
/// Persistence shape:
/// - Storage key: configurable (default `"iris.recent.videos.v1"`).
///   The `.v1` suffix lets future schema changes migrate without
///   trashing existing user MRUs.
/// - Encoded value: `Data` produced by `JSONEncoder().encode([Data])`,
///   where each inner `Data` is a bookmark blob. `JSONEncoder` over
///   `[Data]` yields a JSON array of base64 strings — opaque, durable,
///   and trivially inspectable in `defaults read`.
@MainActor
@Observable
final class RecentVideos {
    /// Default storage key. `.v1` lets future schema bumps migrate cleanly
    /// without clobbering an existing user's MRU.
    static let defaultKey = "iris.recent.videos.v1"

    /// Default cap on stored entries. ~10 is the same ballpark as
    /// `NSDocumentController.recentDocumentURLs`.
    static let defaultLimit = 10

    /// Resolved MRU display state — *raw bookmark blobs* in MRU order
    /// (latest first). Views observe this directly; URL resolution is
    /// done lazily via `resolve()` so the model doesn't hold a strong
    /// list of `URL`s with implicit security-scope semantics.
    private(set) var bookmarks: [Data] = []

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int

    /// - Parameters:
    ///   - defaults: `UserDefaults` instance to read/write. Override for
    ///     tests (`UserDefaults(suiteName:)`) so the test doesn't clobber
    ///     a real user's MRU.
    ///   - key: storage key. Override for tests or future schema bumps.
    ///   - limit: max entries retained. Older entries past this cap are
    ///     dropped on `addOrPromote`.
    init(
        defaults: UserDefaults = .standard,
        key: String = RecentVideos.defaultKey,
        limit: Int = RecentVideos.defaultLimit
    ) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
        self.bookmarks = Self.load(from: defaults, key: key)
    }

    // MARK: - Public API

    /// Add `url` to the MRU. If a matching bookmark already exists,
    /// move it to the front (no duplicates). Trims to `limit` entries.
    ///
    /// "Matching" is determined by resolving each existing bookmark and
    /// comparing the resolved URL's standardized file path to `url`'s
    /// — bookmark-blob byte equality would miss the case where the same
    /// URL was bookmarked twice with slightly different flag combinations.
    /// Bookmark resolution is best-effort; entries that fail to resolve
    /// at this step are dropped (they'd be dropped on the next
    /// `resolve()` call anyway, this just hastens it).
    ///
    /// Bookmark creation flags differ per platform:
    /// - macOS: `[.withSecurityScope, .securityScopeAllowOnlyReadAccess]`
    ///   — required for the sandbox entitlement
    ///   `files.user-selected.read-only`.
    /// - iOS: `[.minimalBookmark]` — iOS demo isn't sandboxed, but
    ///   minimal bookmarks are smaller and resolve more leniently across
    ///   within-sandbox moves than full bookmarks.
    func addOrPromote(_ url: URL) {
        let bookmarkData: Data
        do {
            bookmarkData = try Self.makeBookmark(for: url)
        } catch {
            Logger.recents.error(
                """
                addOrPromote: bookmark creation failed for \
                \(url.lastPathComponent, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """
            )
            return
        }

        // Build the new list: incoming bookmark first, then existing
        // entries excluding any whose resolved URL matches the incoming
        // URL (dedup) or that fail to resolve at all (silent prune).
        var next: [Data] = [bookmarkData]
        let incomingPath = url.standardizedFileURL.path

        for existing in bookmarks {
            // Skip duplicates of the incoming URL.
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
    /// bookmarks fail to resolve, are stale beyond recovery, or point to
    /// files that no longer exist. If `bookmarkDataIsStale == true` but
    /// the URL still resolves to an existing file, refresh the bookmark
    /// in place and persist — this keeps long-lived MRU entries usable
    /// across iCloud Drive sync / `~/Movies` reorganization.
    ///
    /// On macOS the resolved URLs carry a *latent* security scope —
    /// callers must `startAccessingSecurityScopedResource()` / `stop…`
    /// around use, same as URLs from `NSOpenPanel` /
    /// `UIDocumentPickerViewController`. The model does not start the
    /// scope itself; that's the consumer view's responsibility (and it
    /// owns the matching stop).
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

                // Filter entries whose underlying file has been moved
                // out-of-sandbox-reach or deleted. `FileManager.fileExists`
                // doesn't need security-scope access for a `file://` URL's
                // path — but on macOS the sandbox may refuse the stat if
                // the path is outside the granted scope. A failed stat is
                // treated as "missing" and the entry is dropped.
                let exists = FileManager.default.fileExists(atPath: url.path)
                guard exists else {
                    Logger.recents.warning(
                        "resolve: dropping missing \(url.lastPathComponent, privacy: .public)"
                    )
                    continue
                }

                if isStale {
                    // M9·P1·A5: a stale bookmark still resolved to an existing
                    // file — log it so a flaky / repeatedly-refreshing entry is
                    // diagnosable. Refresh the bookmark in place. If the refresh
                    // fails, keep the original blob — the URL still resolved, so
                    // it's usable for *this* session; the user may have to
                    // re-pick later.
                    if let refreshedBlob = try? Self.makeBookmark(for: url) {
                        Logger.recents.notice(
                            "resolve: refreshed stale bookmark for \(url.lastPathComponent, privacy: .public)"
                        )
                        nextBookmarks.append(refreshedBlob)
                        refreshed = true
                    } else {
                        Logger.recents.warning(
                            "resolve: stale bookmark refresh FAILED for \(url.lastPathComponent, privacy: .public); keeping original blob"
                        )
                        nextBookmarks.append(bookmark)
                    }
                } else {
                    nextBookmarks.append(bookmark)
                }

                resolved.append(url)
            } catch {
                Logger.recents.warning(
                    "resolve: dropping unresolvable bookmark: \(String(describing: error), privacy: .public)"
                )
                // Common "user deleted the file" case after a relaunch — now
                // logged at warning level so stale/failed resolves surface.
            }
        }

        // Persist pruning + refresh if anything changed. Avoid a write
        // on the happy path where every bookmark resolved cleanly.
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
            Logger.recents.error(
                "persist: encode failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private static func load(from defaults: UserDefaults, key: String) -> [Data] {
        guard let blob = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([Data].self, from: blob)
        } catch {
            Logger.recents.error(
                "load: decode failed (resetting MRU): \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    // MARK: - Bookmark flag set (platform-gated)

    /// Best-effort resolve that swallows errors and stale-flagged URLs.
    /// Used by `addOrPromote` for dedup; never propagates errors.
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
    fileprivate static let recents = Logger(subsystem: "iris.demo", category: "recents")
}
