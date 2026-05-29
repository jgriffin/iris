import Foundation
import os

/// Orchestrates a **frame-export sweep**: given a list of candidate video
/// sources, fingerprint each, find that asset's flags in the ``FlagStore`` that
/// are not yet written to the ``DatasetSink``, and extract them via
/// ``DatasetBuilder``. The `frames/` directory steadily fills up across runs.
///
/// This is the redefined M7·P4 library core. The app supplies the candidate
/// URLs (it resolves its own `RecentVideos` / security-scoped bookmarks); the
/// library stays ignorant of where they came from — no UserDefaults, no
/// bookmarks, no RecentVideos. Iris only sees `[URL]`.
///
/// ## Resumable / interruptible
///
/// - **Resumable.** Dedup is free via ``DatasetSink/contains(_:)`` — a re-run
///   skips every frame already on disk. A sweep interrupted halfway leaves the
///   PNGs it managed to write; the next sweep extracts only the remainder.
/// - **Interruptible.** ``sweep(sources:)`` calls `Task.checkCancellation()`
///   between sources, and ``DatasetBuilder/extract(flags:from:into:)`` checks
///   between frames, so cancelling stops within ~one frame and throws
///   `CancellationError`. Nothing further is written; already-written frames
///   stay.
///
/// ## Unreachable detection
///
/// After processing the resolvable sources, the sweep compares
/// ``FlagStore/allFlaggedAssets()`` against the fingerprints it actually
/// matched to a source. A flagged asset that (a) was never matched to a
/// resolved source *and* (b) still has frames missing from the sink is
/// **unreachable** — its video isn't in the candidate list. These are reported
/// in ``Summary/unreachable`` so the app can prompt the curator to re-grant
/// access to the missing clips.
///
/// ## Concurrency
///
/// `FrameExporter` is a **`@MainActor` type**. The chosen design fork: the
/// ``FlagStore`` is `@MainActor @Observable`, so all flag reads
/// (``FlagStore/flags(for:)``, ``FlagStore/allFlaggedAssets()``) must happen on
/// the main actor — pinning the exporter there lets those reads be plain
/// synchronous calls with no actor hop. The heavy per-frame decode does **not**
/// block the main thread: ``DatasetBuilder/extract(flags:from:into:)`` is
/// `async` and suspends at every `await` (AVF seek, frame await, sink write),
/// releasing the main actor for the duration. So "flag-store reads on the main
/// actor, decode off it" holds without making the exporter an `actor` (which
/// would only force awkward hops back to the `@MainActor` store).
@MainActor
public final class FrameExporter {

    /// A flagged asset the sweep could not reach: no candidate URL fingerprinted
    /// to its `id`, and frames are still missing from the sink.
    public struct UnreachableSource: Sendable, Equatable, Codable {
        /// Content fingerprint id of the unreached asset.
        public let fingerprintID: String
        /// Display filename from the stored ``AssetFingerprint/filename``.
        public let displayFilename: String
        /// How many of its flagged frames are still absent from the sink.
        public let pendingCount: Int

        public init(fingerprintID: String, displayFilename: String, pendingCount: Int) {
            self.fingerprintID = fingerprintID
            self.displayFilename = displayFilename
            self.pendingCount = pendingCount
        }
    }

    /// Per-asset breakdown of one sweep's work against a resolved source.
    public struct AssetResult: Sendable, Equatable, Codable {
        public let fingerprintID: String
        public let displayFilename: String
        public let written: Int
        public let skipped: Int
        public let noFrame: Int

        public init(
            fingerprintID: String,
            displayFilename: String,
            written: Int,
            skipped: Int,
            noFrame: Int
        ) {
            self.fingerprintID = fingerprintID
            self.displayFilename = displayFilename
            self.written = written
            self.skipped = skipped
            self.noFrame = noFrame
        }
    }

    /// Aggregate result of a sweep: rolled-up counts, per-asset breakdown, and
    /// the unreachable list.
    public struct Summary: Sendable, Equatable, Codable {
        /// Frames newly written to the sink this sweep.
        public var written: Int
        /// Frames skipped because the sink already held them (dedup / resume).
        public var skipped: Int
        /// Frames whose re-seek produced no decodable image.
        public var noFrame: Int
        /// Per-resolved-asset breakdown, in source-processing order.
        public var assets: [AssetResult]
        /// Flagged assets with pending frames that no candidate source resolved.
        public var unreachable: [UnreachableSource]

        public init(
            written: Int = 0,
            skipped: Int = 0,
            noFrame: Int = 0,
            assets: [AssetResult] = [],
            unreachable: [UnreachableSource] = []
        ) {
            self.written = written
            self.skipped = skipped
            self.noFrame = noFrame
            self.assets = assets
            self.unreachable = unreachable
        }
    }

    private let store: FlagStore
    private let builder: DatasetBuilder
    private static let logger = Logger(subsystem: "iris.dataset", category: "FrameExporter")

    /// - Parameters:
    ///   - store: the flag store to read flagged frames from (read on the main
    ///     actor — see the type's Concurrency note).
    ///   - builder: the headless extractor. Defaults to a fresh
    ///     ``DatasetBuilder``.
    public init(store: FlagStore, builder: DatasetBuilder = DatasetBuilder()) {
        self.store = store
        self.builder = builder
    }

    // MARK: - Sweep

    /// Sweep `sources`: for each URL, fingerprint it, look up its flags, and
    /// extract the pending ones into `sink`. Then report any flagged asset that
    /// no source resolved and that still has frames missing as
    /// ``Summary/unreachable``.
    ///
    /// - Parameters:
    ///   - sources: candidate video URLs (the app resolves these). Order is the
    ///     processing order; the per-asset breakdown follows it.
    ///   - sink: destination for extracted PNGs.
    ///   - statusURL: optional path to persist last-run telemetry to. When
    ///     non-nil, ``ExportStatus`` is written there as `export-status.json`.
    ///     Pass `nil` to skip persistence (tests that only inspect the returned
    ///     `Summary`). Use ``statusURL(baseDir:)`` for the standard location.
    ///   - ranAt: optional caller-supplied run timestamp recorded in the
    ///     persisted status. The exporter never reads the clock itself — pass
    ///     `Date()` from the app if you want the field populated.
    /// - Returns: the aggregate ``Summary``.
    /// - Throws: `CancellationError` if the enclosing `Task` is cancelled
    ///   (checked between sources and, inside the builder, between frames).
    ///   Already-written frames are left in place.
    @discardableResult
    public func sweep(
        sources: [URL],
        into sink: some DatasetSink,
        statusURL: URL? = nil,
        ranAt: Date? = nil
    ) async throws -> Summary {
        var summary = Summary()
        var matchedIDs = Set<String>()

        for url in sources {
            // Interruptible: stop promptly between sources. The builder adds a
            // second checkpoint between frames.
            try Task.checkCancellation()

            let fingerprint: AssetFingerprint
            do {
                fingerprint = try await AssetFingerprint.compute(url: url)
            } catch {
                Self.logger.error(
                    "sweep: fingerprint failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                continue
            }

            matchedIDs.insert(fingerprint.id)

            // Flag reads happen here on the main actor (FlagStore is @MainActor).
            let flags = store.flags(for: fingerprint)
            guard !flags.isEmpty else { continue }

            let assetSummary = try await builder.extract(flags: flags, from: url, into: sink)
            summary.written += assetSummary.written
            summary.skipped += assetSummary.skipped
            summary.noFrame += assetSummary.noFrame
            summary.assets.append(
                AssetResult(
                    fingerprintID: fingerprint.id,
                    displayFilename: fingerprint.filename,
                    written: assetSummary.written,
                    skipped: assetSummary.skipped,
                    noFrame: assetSummary.noFrame
                )
            )
        }

        summary.unreachable = unreachableAssets(matchedIDs: matchedIDs, sink: sink)

        if let statusURL {
            persistStatus(summary, to: statusURL, ranAt: ranAt)
        }
        return summary
    }

    /// Compare every flagged asset on disk against the fingerprints matched to a
    /// resolved source. A flagged asset is unreachable when it was never matched
    /// *and* still has frames the sink doesn't hold.
    private func unreachableAssets(
        matchedIDs: Set<String>,
        sink: some DatasetSink
    ) -> [UnreachableSource] {
        var unreachable: [UnreachableSource] = []
        for (asset, flags) in store.allFlaggedAssets() {
            guard !matchedIDs.contains(asset.id) else { continue }
            let pending = flags.filter { !sink.contains($0.ref) }
            guard !pending.isEmpty else { continue }
            unreachable.append(
                UnreachableSource(
                    fingerprintID: asset.id,
                    displayFilename: asset.filename,
                    pendingCount: pending.count
                )
            )
        }
        return unreachable
    }

    // MARK: - export-status.json

    /// Last-run operational telemetry persisted to
    /// `<baseDir>/iris-dataset/export-status.json`.
    ///
    /// ## This is NOT a per-frame provenance sidecar
    ///
    /// Iris deliberately ships **no per-image `.json` sidecar** — annotations
    /// are recovered from the ``FlagStore`` (keyed by content fingerprint) and a
    /// future `COCOExporter` will emit a single dataset-level manifest, not
    /// per-frame fragments (see ``DatasetSink`` "No per-image sidecar"). This
    /// `export-status.json` does not revert that decision: it is a single,
    /// overwritten file describing the *last sweep run* (counts + which flagged
    /// assets couldn't be reached) so the app can show "X written, Y
    /// unreachable" without re-scanning. It carries no per-frame provenance and
    /// is safe to delete — the next sweep regenerates it.
    public struct ExportStatus: Sendable, Equatable, Codable {
        /// Schema version, for forward migration.
        public var version: Int
        /// Optional caller-supplied run timestamp. The library never calls
        /// `Date()` itself (keeps sweeps testable); the app passes one if it
        /// wants the field populated.
        public var ranAt: Date?
        public var written: Int
        public var skipped: Int
        public var noFrame: Int
        public var unreachable: [UnreachableSource]

        public init(
            version: Int = FrameExporter.statusSchemaVersion,
            ranAt: Date? = nil,
            written: Int,
            skipped: Int,
            noFrame: Int,
            unreachable: [UnreachableSource]
        ) {
            self.version = version
            self.ranAt = ranAt
            self.written = written
            self.skipped = skipped
            self.noFrame = noFrame
            self.unreachable = unreachable
        }
    }

    /// On-disk schema version for ``ExportStatus``. `nonisolated` so the nested
    /// (non-isolated) ``ExportStatus`` can use it as a default in its `init`.
    public nonisolated static let statusSchemaVersion = 1

    /// Standard location for the status file under an injected dataset root,
    /// alongside `flags/` and `frames/`: `<baseDir>/iris-dataset/export-status.json`.
    public nonisolated static func statusURL(baseDir: URL) -> URL {
        baseDir
            .appendingPathComponent("iris-dataset", isDirectory: true)
            .appendingPathComponent("export-status.json", isDirectory: false)
    }

    /// Build the ``ExportStatus`` for a sweep `summary`. `ranAt` is injected by
    /// the caller — the exporter never reads the clock itself.
    public func status(for summary: Summary, ranAt: Date? = nil) -> ExportStatus {
        ExportStatus(
            ranAt: ranAt,
            written: summary.written,
            skipped: summary.skipped,
            noFrame: summary.noFrame,
            unreachable: summary.unreachable
        )
    }

    private func persistStatus(_ summary: Summary, to url: URL, ranAt: Date?) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(status(for: summary, ranAt: ranAt))
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error(
                "persistStatus: write failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
