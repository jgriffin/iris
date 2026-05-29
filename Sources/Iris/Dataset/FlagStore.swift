import Foundation
import Observation
import os

/// Iris's first library-side on-disk persistence: an `@MainActor`
/// `@Observable` store of per-asset frame flags.
///
/// Mirrors the house idiom from `Apps/Shared/RecentVideos.swift`
/// (`@MainActor @Observable` single-writer + `JSONEncoder`/`Decoder` +
/// `.v1`-versioned schema), but persists to the filesystem instead of
/// `UserDefaults` because flag sets can grow large and are keyed per asset.
///
/// ## Layout
///
/// One JSON file per asset, named by the asset's **content** fingerprint:
///
/// ```
/// <baseDir>/iris-dataset/flags/<fingerprint.id>.json
/// ```
///
/// Each file is a versioned envelope wrapping a `[FrameFlag]`. Because the
/// filename is the content-derived `id`, reloading the *same video* — even at
/// a different path or name — resolves to the *same* flag file, delivering
/// M7's "reload same video → same flags" guarantee.
///
/// ## baseDir injection (no hardcoded paths)
///
/// The library does **not** know the app's sandbox. `baseDir` is injected by
/// the consumer (the demo passes its Documents dir). This keeps Iris's
/// "no hardcoded paths" discipline and lets tests point at a temp dir.
///
/// ## Loading
///
/// Flags load **lazily**, per asset, on first access, and are cached in
/// memory keyed by `fingerprint.id`. Mutations update the cache and rewrite
/// that asset's file atomically.
///
/// ## Concurrency
///
/// `@MainActor` single-writer: all mutation and persistence happen on the
/// main actor so `@Observable` publishes stay ordered with disk writes.
@MainActor
@Observable
public final class FlagStore {

    /// On-disk schema version. Bump when the persisted shape changes so old
    /// files can be migrated rather than silently mis-decoded.
    static let schemaVersion = 1

    /// Versioned persistence envelope. `.v1` lets future schema bumps migrate
    /// without trashing existing flag files.
    private struct StoredFlags: Codable {
        var version: Int
        var flags: [FrameFlag]
    }

    /// Injected root. Flag files live under `<baseDir>/iris-dataset/flags/`.
    private let baseDir: URL

    /// In-memory cache, keyed by `AssetFingerprint.id`. `nil` (absent key)
    /// means "not loaded yet"; an empty array means "loaded, no flags."
    private var cache: [String: [FrameFlag]] = [:]

    private static let logger = Logger(subsystem: "iris.dataset", category: "FlagStore")

    /// - Parameter baseDir: app-injected root directory. Flag files are
    ///   written under `<baseDir>/iris-dataset/flags/`. The library never
    ///   hardcodes this — pass the app's Documents dir (or a temp dir in
    ///   tests).
    public init(baseDir: URL) {
        self.baseDir = baseDir
    }

    // MARK: - Public API

    /// All flags currently stored for `asset`, loading from disk on first
    /// access and caching thereafter. Order is load/insertion order.
    public func flags(for asset: AssetFingerprint) -> [FrameFlag] {
        loaded(asset.id)
    }

    /// Whether a flag exists at exactly this frame address. Identity is the
    /// `FrameRef` (asset + exact PTS).
    public func isFlagged(_ ref: FrameRef) -> Bool {
        loaded(ref.asset.id).contains { $0.ref == ref }
    }

    /// Every flagged asset on disk, paired with its flags.
    ///
    /// Where ``flags(for:)`` resolves one *known* asset, this scans the entire
    /// `<baseDir>/iris-dataset/flags/` directory so callers (the export sweep)
    /// can reason about "everything that was ever flagged" without first
    /// knowing which assets exist. Each `FrameFlag.ref.asset` carries the full
    /// `AssetFingerprint`, so the asset is reconstructed from the flag records
    /// themselves — no external input needed.
    ///
    /// Respects the load/cache discipline: a flag file that has already been
    /// loaded is served from `cache`; un-cached files are loaded (and cached)
    /// here. Files that fail to decode are skipped (logged in ``load(id:)``).
    /// Assets whose stored flag list is empty are omitted — there is nothing
    /// to sweep for them.
    public func allFlaggedAssets() -> [(asset: AssetFingerprint, flags: [FrameFlag])] {
        let ids: [String]
        do {
            ids = try FileManager.default
                .contentsOfDirectory(atPath: flagsDir.path)
                .filter { $0.hasSuffix(".json") }
                .map { String($0.dropLast(".json".count)) }
        } catch {
            // No flags/ dir yet ⇒ nothing flagged.
            return []
        }

        var result: [(asset: AssetFingerprint, flags: [FrameFlag])] = []
        for id in ids {
            let flags = loaded(id)
            guard let asset = flags.first?.ref.asset else { continue }
            result.append((asset: asset, flags: flags))
        }
        return result
    }

    /// Toggle a flag at `flag.ref`: remove the existing flag at that address
    /// if present, otherwise add this one. The unit of identity is the
    /// `FrameRef`, so re-flagging the same frame with different metadata
    /// replaces by removal — matching a bookmark-toggle affordance.
    public func toggle(_ flag: FrameFlag) {
        if isFlagged(flag.ref) {
            remove(flag.ref)
        } else {
            add(flag)
        }
    }

    /// Add `flag`, replacing any existing flag at the same `FrameRef` so a
    /// frame never carries two flags. Persists the asset's file.
    public func add(_ flag: FrameFlag) {
        let id = flag.ref.asset.id
        var flags = loaded(id)
        flags.removeAll { $0.ref == flag.ref }
        flags.append(flag)
        cache[id] = flags
        persist(id: id, flags: flags)
    }

    /// Remove the flag at `ref`, if any. Persists the asset's file when a
    /// flag was actually removed.
    public func remove(_ ref: FrameRef) {
        let id = ref.asset.id
        var flags = loaded(id)
        let before = flags.count
        flags.removeAll { $0.ref == ref }
        guard flags.count != before else { return }
        cache[id] = flags
        persist(id: id, flags: flags)
    }

    // MARK: - Lazy load + cache

    /// Return the cached flags for an asset id, loading from disk on first
    /// access.
    private func loaded(_ id: String) -> [FrameFlag] {
        if let cached = cache[id] { return cached }
        let loaded = load(id: id)
        cache[id] = loaded
        return loaded
    }

    // MARK: - Persistence

    private var flagsDir: URL {
        baseDir
            .appendingPathComponent("iris-dataset", isDirectory: true)
            .appendingPathComponent("flags", isDirectory: true)
    }

    private func fileURL(id: String) -> URL {
        flagsDir.appendingPathComponent("\(id).json", isDirectory: false)
    }

    private func load(id: String) -> [FrameFlag] {
        let url = fileURL(id: id)
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            let stored = try JSONDecoder().decode(StoredFlags.self, from: data)
            // Single-version world today; a future bump would migrate here.
            return stored.flags
        } catch {
            Self.logger.error(
                "load: decode failed for \(id, privacy: .public) (treating as empty): \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    private func persist(id: String, flags: [FrameFlag]) {
        let dir = flagsDir
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            let stored = StoredFlags(version: Self.schemaVersion, flags: flags)
            let data = try JSONEncoder().encode(stored)
            // Atomic write so a crash mid-write can't leave a truncated file.
            try data.write(to: fileURL(id: id), options: .atomic)
        } catch {
            Self.logger.error(
                "persist: write failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
