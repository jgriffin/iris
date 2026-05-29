import Foundation
import Iris
import Observation
import os

/// Drives the M7·P4 **frame-export sweep** from the demo apps: resolves the
/// `RecentVideos` MRU into candidate URLs, holds their security scope for the
/// duration of a sweep, and runs `FrameExporter.sweep(...)` so the dataset's
/// `frames/` directory fills up automatically as the curator flags.
///
/// **Why this lives in `Apps/Shared/`, not the Iris package.** The library
/// (`FrameExporter`) is deliberately ignorant of *where* candidate URLs come
/// from — no `UserDefaults`, no bookmarks, no `RecentVideos` (see the type
/// doc on `FrameExporter`). Resolving bookmarks and managing security scope are
/// consumer concerns, and the orchestration (resolve → start-scope → sweep →
/// stop-scope, plus trigger debouncing) is identical on iOS and macOS — so it
/// lives here once and both demo `ContentView`s drive it, rather than each
/// duplicating the dance.
///
/// **Security scope (critical on iOS / sandboxed macOS).** A URL resolved from
/// a `RecentVideos` bookmark carries a *latent* security scope. The sweep opens
/// each as a headless `PlaybackSource`, so the scope must be held for the WHOLE
/// sweep: every resolvable URL gets `startAccessingSecurityScopedResource()`
/// before the sweep and a matching `stop…` in a `defer` after it returns.
/// Bookmarks that fail to resolve are simply absent from `resolve()`'s output
/// (the model prunes them) — the sweep's `unreachable` reporting covers any
/// flagged asset with no live source.
///
/// **Overlap + cancellation.** Sweeps run in a single cancellable `Task` held
/// on this coordinator. A new trigger cancels nothing by default *unless* asked
/// to — `triggerSweep()` is a no-op while one is already running (overlap
/// guard), and `cancelInFlight()` cancels the running sweep (cheap: the library
/// checks `Task.checkCancellation()` between sources/frames, and a re-run
/// resumes via the sink's dedup). The app cancels on returning to the
/// foreground and kicks a fresh sweep on launch / backgrounding.
@MainActor
@Observable
final class FrameExportCoordinator {

    private let exporter: FrameExporter
    private let sink: FolderDatasetSink
    private let statusURL: URL
    @ObservationIgnored private unowned let recentVideos: RecentVideos

    /// The in-flight sweep, if any. Held so a foreground transition can cancel
    /// it and so `triggerSweep()` can guard against starting a second.
    @ObservationIgnored private var sweepTask: Task<Void, Never>?

    /// Last sweep's result, for the "Export now" status line. `nil` until the
    /// first sweep completes (or stays `nil` if it was cancelled before
    /// finishing).
    private(set) var lastSummary: FrameExporter.Summary?

    /// `true` while a sweep is running. Drives the button's progress affordance
    /// and the overlap guard.
    private(set) var isSweeping = false

    private static let logger = Logger(subsystem: "iris.demo", category: "dataset-export")

    /// - Parameters:
    ///   - store: the SAME `FlagStore` the demo's `FlaggingModel` writes to, so
    ///     the sweep reads exactly the flags the user set.
    ///   - baseDir: the demo's Documents dir — `frames/` and `export-status.json`
    ///     land under `<baseDir>/iris-dataset/`, beside the store's `flags/`.
    ///   - recentVideos: the MRU model the sweep resolves into candidate URLs.
    init(store: FlagStore, baseDir: URL, recentVideos: RecentVideos) {
        self.exporter = FrameExporter(store: store)
        self.sink = FolderDatasetSink(baseDir: baseDir)
        self.statusURL = FrameExporter.statusURL(baseDir: baseDir)
        self.recentVideos = recentVideos
    }

    // MARK: - Triggers

    /// Kick a sweep unless one is already running (overlap guard). Used by the
    /// launch and background triggers — fire-and-forget; the result lands in
    /// `lastSummary`.
    func triggerSweep() {
        guard !isSweeping else {
            Self.logger.debug("triggerSweep: skipped — a sweep is already running")
            return
        }
        startSweep()
    }

    /// Force a sweep immediately, awaiting its completion, and return the
    /// `Summary` for the "Export now" button to display. If a sweep is already
    /// running, awaits *that* one rather than starting a second (overlap guard),
    /// then returns the latest summary.
    @discardableResult
    func exportNow() async -> FrameExporter.Summary? {
        if !isSweeping {
            startSweep()
        }
        await sweepTask?.value
        return lastSummary
    }

    /// Cancel any in-flight sweep. Called on returning to the foreground —
    /// cancellation is cheap (cooperative, checked between sources/frames) and
    /// already-written frames stay; the next sweep resumes via the sink's dedup.
    func cancelInFlight() {
        sweepTask?.cancel()
    }

    // MARK: - Sweep body

    /// Resolve candidates, hold their security scope, and run one sweep. Stores
    /// the task so it can be cancelled / awaited. Idempotent against overlap via
    /// the `isSweeping` guard in the callers.
    private func startSweep() {
        isSweeping = true
        sweepTask = Task { [exporter, sink, statusURL, recentVideos] in
            defer {
                self.isSweeping = false
                self.sweepTask = nil
            }

            // Resolve MRU bookmarks → URLs. Stale/unresolvable entries are
            // pruned inside `resolve()` and simply absent here; their flagged
            // frames surface as `unreachable` in the Summary.
            let sources = recentVideos.resolve()

            // Hold security scope for the WHOLE sweep — the headless
            // PlaybackSource reads each URL; on iOS / sandboxed macOS the AVF
            // read fails if the scope isn't held. Track which URLs we actually
            // started so the `defer` only stops those (a denied start must not
            // be paired with a stop).
            var scoped: [URL] = []
            for url in sources where url.startAccessingSecurityScopedResource() {
                scoped.append(url)
            }
            defer {
                for url in scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let summary = try await exporter.sweep(
                    sources: scoped,
                    into: sink,
                    statusURL: statusURL,
                    ranAt: Date()
                )
                self.lastSummary = summary
                Self.logger.info(
                    """
                    sweep complete: \(summary.written, privacy: .public) written, \
                    \(summary.skipped, privacy: .public) skipped, \
                    \(summary.unreachable.count, privacy: .public) unreachable
                    """
                )
            } catch is CancellationError {
                Self.logger.debug("sweep cancelled — already-written frames kept; will resume next run")
            } catch {
                Self.logger.error(
                    "sweep failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }
}

// MARK: - Summary display helper

extension FrameExporter.Summary {
    /// One-line human summary for the demo status line, e.g.
    /// `"7 written · 3 skipped · 2 unreachable: dancer.mov, clip2.mov"`.
    var demoStatusLine: String {
        var parts = ["\(written) written", "\(skipped) skipped"]
        if noFrame > 0 {
            parts.append("\(noFrame) no-frame")
        }
        if !unreachable.isEmpty {
            let names = unreachable
                .prefix(3)
                .map(\.displayFilename)
                .joined(separator: ", ")
            let suffix = unreachable.count > 3 ? ", …" : ""
            parts.append("\(unreachable.count) unreachable: \(names)\(suffix)")
        }
        return parts.joined(separator: " · ")
    }
}
