import Foundation
import Observation

// MARK: - ImageDetectionCoordinator

/// Owns the **one-shot image detection-session orchestration**: a held still
/// `Frame`, a `DetectionRunner` run once on load, and the detector swap that
/// re-runs detection on that same held frame. The image analogue of
/// [`PlaybackDetectionCoordinator`](../Playback/PlaybackDetectionCoordinator.swift)
/// — same composed core, no time axis.
///
/// **Composes a `DetectionRunner` (M8·P1).** The source-agnostic core — the
/// `ResultStore` + `DetectionMetrics`, the `ActiveDetectorSession` built from a
/// catalog entry, and the per-frame "run + time + record" unit — lives in
/// [`DetectionRunner`](../Detection/DetectionRunner.swift); the playback
/// coordinator composes the same type. This coordinator adds the *image* layer,
/// which is deliberately thin: a held `Frame` instead of a `PlaybackController`,
/// and a **re-detect-the-held-frame** re-emit hook instead of playback's seek.
/// The runner's `resultStore` / `metrics` / `session` are re-surfaced here
/// unchanged so the demo's library-view bindings match the playback page's.
///
/// **A still is one-shot — there is no detect loop (M8 decision, 2026-05-29).**
/// A static image has no time axis, so this does **not** route a 1-frame
/// `AsyncStream<Frame>` through the playback streaming loop (that would fork a
/// type's shape to serve two sources — the anti-pattern the project forbids).
/// Instead it calls `runner.run(on:)` exactly once per intent: once on load,
/// once per detector swap, once per `.detector`-tier tuning change. The frame is
/// held in memory for the coordinator's lifetime so every re-run hits the same
/// pixels — the whole point of the image inspector (`plans/features/M8.md` §P3).
///
/// **Detector swap = invalidate cache → in-place session swap → re-detect.**
/// `selectDetector` invalidates the cache (the old detections came from a
/// different detector), installs the new session in place via the runner, then
/// re-runs the held frame so the overlay redraws under the new detector. There
/// is no stream to re-consume and no race, so no drain/respawn dance — the
/// one-shot call *is* the swap.
///
/// **The re-emit hook re-detects the held frame.** A `.detector`-tier tuning
/// knob (e.g. a confidence threshold backed by the model, not a post-filter)
/// invalidates the cache via the session's cache wiring; the runner fires the
/// installed `onDetectorTierChange` hook, which here re-runs `run(on:)` on the
/// held frame to repopulate the store under the new settings. This is the image
/// counterpart of playback's "seek to the current time to re-emit while paused."
/// A `PassthroughRouter` (non-tunable detector) never fires it — a harmless
/// no-op, same as on the playback path.
///
/// **What stays in the demo (the outer layer).** Decoding the picked still into
/// a `Frame` (the demo owns `ImageFrameDecoder`, the file picker, security-scoped
/// bookmarks, and the `RecentImages` MRU — exactly as it owns `PlaybackSource`
/// construction on the playback page), the detector catalog + custom-model UX,
/// and wiring the library views to this coordinator's outputs. The demo hands a
/// decoded `Frame` in; the coordinator never touches disk or EXIF.
///
/// **Concurrency.** `@MainActor @Observable`, mirroring the playback
/// coordinator's idiom: a SwiftUI-shaped observable fronting the non-MainActor
/// inference. The heavy `runner.run(on:)` is `nonisolated`, so the inference
/// runs off the main actor and hops back only to read the router + record the
/// gauge.
@MainActor
@Observable
public final class ImageDetectionCoordinator {

    // MARK: - Source-agnostic core

    /// The shared detection core: cache + metrics + active session + per-frame
    /// inference. This coordinator drives it one-shot; the playback coordinator
    /// drives the same type from a frame-stream loop.
    public let runner: DetectionRunner

    // MARK: - Outputs the demo binds its library views to

    /// Detection cache. → `DetectionLayer(store:)` + `DetectionInspector(store:)`.
    /// Re-surfaced from the runner so bindings match the playback page.
    public var resultStore: ResultStore { runner.resultStore }

    /// Best-effort pipeline gauge. → `DetectionMetricsView(metrics:)`.
    /// Re-surfaced from the runner. For a still only inference time + processed
    /// count move; there is no stream, so drop/emit counts stay zero.
    public var metrics: DetectionMetrics { runner.metrics }

    /// The active detector session. → `.router` for `DetectionLayer(tuning:)`,
    /// `.settingsView` for the tuning sheet. Re-surfaced from the runner; `nil`
    /// before the first `setImage` and after `clear`. Swapped in place by
    /// `selectDetector`.
    public var session: ActiveDetectorSession? { runner.session }

    /// The held still being inspected. → overlay `contentSize` (`.dimensions`)
    /// and `displayTimeSource` (`.timestamp`, a frozen value — a still's lookup
    /// always asks for that one bucket). `nil` before the first `setImage` and
    /// after `clear`.
    public private(set) var frame: Frame?

    // MARK: - Init

    /// Build a coordinator holding the supplied cache + metrics (forwarded to its
    /// `DetectionRunner`). Both default to fresh instances; the demo can inject
    /// its own to share them with other UI before an image is set.
    public init(
        resultStore: ResultStore = .init(),
        metrics: DetectionMetrics = .init()
    ) {
        self.runner = DetectionRunner(resultStore: resultStore, metrics: metrics)
    }

    // MARK: - Intent 1: a new image

    /// Hold `frame` and detect it once with `entry`.
    ///
    /// Resets the cache + metrics for the new image, installs the detector
    /// session (wiring the re-detect re-emit hook), and runs the pipeline a
    /// single time. The demo decodes the picked still into the `Frame` (it owns
    /// `ImageFrameDecoder` + the security scope) and hands it in — mirroring how
    /// the playback page builds the `PlaybackSource` and hands the source in.
    public func setImage(
        _ frame: Frame,
        detector entry: DetectorCatalogEntry
    ) async {
        // Per-image cache + metrics reset, then hold the new still.
        runner.resetForNewSession()
        self.frame = frame

        installSession(entry: entry, on: frame)
        await runner.run(on: frame)
    }

    // MARK: - Intent 2: swap the detector, keep the image

    /// Swap the active detector to `entry`, keeping the held image, and re-detect.
    ///
    /// Invalidates the cache (old detections came from a different detector),
    /// resets metrics, installs the new session in place, then re-runs the held
    /// frame so the overlay redraws under the new detector. No-op if no image is
    /// set. The one-shot re-run *is* the swap — no stream to re-consume.
    public func selectDetector(_ entry: DetectorCatalogEntry) async {
        guard let frame else { return }

        runner.resetForNewSession()
        installSession(entry: entry, on: frame)
        await runner.run(on: frame)
    }

    // MARK: - Teardown

    /// Drop the session + held image. Idempotent. Clears the session (and its
    /// re-emit hook) so no stale tier-change fire can cross the boundary, then
    /// releases the frame and clears the cache.
    public func clear() {
        runner.clearSession()
        frame = nil
        runner.resultStore.clear()
    }

    // MARK: - Private

    /// Install the catalog session for `entry` via the runner, supplying the
    /// image-specific re-emit hook: a `.detector`-tier tuning change invalidates
    /// the cache via the session's cache wiring, then this hook re-runs the held
    /// frame so the overlay repopulates under the new settings — the still's
    /// analogue of playback's seek-to-re-emit. A `PassthroughRouter` (non-tunable
    /// detector) never fires it, so the wiring is a harmless no-op there.
    private func installSession(
        entry: DetectorCatalogEntry,
        on frame: Frame
    ) {
        runner.installSession(entry: entry) { [weak self] in
            guard let self else { return }
            // The held frame may have changed/cleared between the knob change and
            // this fire; re-read it rather than capturing the load-time value.
            guard let current = self.frame else { return }
            Task { await self.runner.run(on: current) }
        }
    }
}
