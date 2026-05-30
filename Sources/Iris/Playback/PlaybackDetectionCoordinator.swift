import Foundation
import Observation

// MARK: - PlaybackDetectionCoordinator

/// Owns the playback **detection-session orchestration** the two demos used
/// to duplicate verbatim: the per-source detect loop and its lifecycle, the
/// self-wired `onDetectorTierChange` pause-emit hook, and the
/// `PlaybackController` lifecycle + ordered teardown.
///
/// **Composes a `DetectionRunner` (M8·P1).** The source-agnostic core — the
/// `ResultStore` + `DetectionMetrics`, the `ActiveDetectorSession` built from a
/// catalog entry, and the per-frame "run + time + record" unit — now lives in
/// [`DetectionRunner`](../Detection/DetectionRunner.swift), which the image
/// inspector also composes. This coordinator adds the *playback* layer: the
/// frame-stream detect loop, the `PlaybackController` lifecycle, the
/// source-specific drop/emit counter bridge, and the seek-based re-emit hook.
/// The runner's `resultStore` / `metrics` / `session` are re-surfaced here
/// unchanged so the demo's library-view bindings are stable.
///
/// **Why this layer lives in `Playback/`.** It is playback-coupled — the
/// pause-emit hook needs a `PlaybackController` + `seek` to re-emit the visible
/// frame so a `.detector`-tier change shows through while paused.
///
/// **Detector swap is an in-place session swap — NOT a loop respawn.**
/// `PlaybackSource.frames` is a *single-iteration* `AsyncStream`: cancelling
/// the consuming task **finishes the stream**, so a second `for await` over
/// the same `frames` receives nothing (verified empirically; this is plain
/// `AsyncStream` semantics, not a `PlaybackSource` quirk). The coordinator
/// therefore spawns **one** detect loop per source, alive for the source's
/// lifetime, and a detector swap replaces the runner's active `session` (and
/// its router) *in place*. The loop hands each frame to `runner.run(on:)`,
/// which reads the live router and runs `DetectorPipeline.detect(in:cache:tuning:)`,
/// whose hot-swap contract runs `router.currentDetector`. That makes the
/// freshly-selected detector the sole producer for every subsequent frame,
/// with no stream re-iteration and no two-consumer race. (This is a
/// deliberate departure from the demos' cancel→drain→respawn glue, which the
/// single-iteration property makes non-functional for the new loop — see the
/// feature plan and the LOG.)
///
/// **What stays in the demo (the outer layer).** Screen composition, source
/// selection UX (`.fileImporter` / `DocumentPicker`, **security-scoped
/// bookmarks**, MRU, bundled-fixture choice), the detector catalog + custom-
/// model UX, and wiring the library views to this coordinator's outputs.
/// The demo builds the `PlaybackSource` (it holds the security scope) and
/// hands the *source* in; the coordinator never touches scope.
///
/// **Sandbox-scope ordering contract (load-bearing).** `setSource` and
/// `teardown` are `async` and only return once the *prior* source's
/// `invalidate()` has completed. The demo must release the security-scoped
/// resource (`stopAccessingSecurityScopedResource()`) **strictly after** the
/// `await` returns — AVF must not read from a URL whose scope was already
/// dropped. The P1 swap test asserts this return-after-invalidate ordering.
///
/// **Non-tunable detectors.** A plain-`Detector` catalog entry
/// (`DetectorCatalogEntry.make(id:displayName:detector:)`) yields a
/// `PassthroughRouter` + `EmptyView` settings view. The coordinator wires
/// the pause-emit hook the same way regardless — `PassthroughRouter` never
/// fires `onDetectorTierChange`, so the wiring is a harmless no-op consumer.
/// No special-casing; nothing here assumes tunability.
///
/// **Concurrency.** `@MainActor @Observable`, mirroring the
/// [`PlaybackController`](./PlaybackController.swift) /
/// [`ResultStore`](../Overlay/ResultStore.swift) idiom: a SwiftUI-shaped
/// observable that fronts a non-MainActor frame pipeline without leaking the
/// underlying threading model. The detect loop runs off the main actor and
/// hops (inside `runner.run(on:)`) to read the current router + record metrics.
@MainActor
@Observable
public final class PlaybackDetectionCoordinator {

    // MARK: - Source-agnostic core

    /// The shared detection core: cache + metrics + active session + per-frame
    /// inference. This coordinator drives it from a frame-stream loop; the image
    /// inspector drives the same type one-shot.
    public let runner: DetectionRunner

    // MARK: - Outputs the demo binds its library views to

    /// Detection cache. → `DetectionLayer(store:)` + `DetectionInspector(store:)`.
    /// Re-surfaced from the runner so existing bindings are stable.
    public var resultStore: ResultStore { runner.resultStore }

    /// Best-effort pipeline gauge. → `DetectionMetricsView(metrics:)`.
    /// Re-surfaced from the runner.
    public var metrics: DetectionMetrics { runner.metrics }

    /// The active detector session. → `.router` for `DetectionLayer(tuning:)`,
    /// `.settingsView` for the tuning sheet. Re-surfaced from the runner; `nil`
    /// before the first `setSource` and after `teardown`. Swapped in place by
    /// `selectDetector`.
    public var session: ActiveDetectorSession? { runner.session }

    /// The active playback controller, created per source. → `Scrubber(model:)`
    /// + `PlaybackView(source: controller.source)`. `nil` before the first
    /// `setSource` and after `teardown`.
    public private(set) var controller: PlaybackController?

    /// The most recently processed live frame, updated on the @MainActor each
    /// time the detect loop pulls one. → the demo's "Inspect frame"
    /// freeze-from-live affordance (M8·P5), which hands this still to the image
    /// inspector. Mirrors `ImageDetectionCoordinator.frame`. `nil` before the
    /// first frame flows and after `teardown`; sticky between sources otherwise
    /// (the last visible frame is the one worth inspecting).
    public private(set) var currentFrame: Frame?

    // MARK: - Stored

    /// The single per-source detect loop. Spawned in `setSource`, cancelled in
    /// `teardown`. Never respawned for a detector swap (the stream is
    /// single-iteration — see the type doc).
    @ObservationIgnored private var detectionTask: Task<Void, Never>?

    // MARK: - Init

    /// Build a coordinator holding the supplied cache + metrics (forwarded to
    /// its `DetectionRunner`). Both default to fresh instances; the demo can
    /// inject its own if it needs to share them with other UI before a source
    /// is set.
    public init(
        resultStore: ResultStore = .init(),
        metrics: DetectionMetrics = .init()
    ) {
        self.runner = DetectionRunner(resultStore: resultStore, metrics: metrics)
    }

    // MARK: - Intent 1: a new video

    /// Point the coordinator at a new source and start detecting with `entry`.
    ///
    /// Tears down any prior session first (cancel detect loop → drain →
    /// `invalidate()`), resets the cache + metrics for the new session, builds
    /// a `PlaybackController` for `source`, constructs the detector session,
    /// and spawns the single per-source detect loop. Playback is **not**
    /// started — the demo calls `coordinator.controller?.togglePlay()` after
    /// this returns, so it can sequence playback start against its own UI.
    ///
    /// **Scope ordering:** the prior source's `invalidate()` has completed by
    /// the time this returns — see the type's sandbox-scope contract.
    public func setSource(
        _ source: PlaybackSource,
        detector entry: DetectorCatalogEntry
    ) async {
        // Tear the prior session down completely (and wait for its source to
        // invalidate) before standing up the new one. Mirrors the demo's
        // "teardown FIRST" ordering.
        await teardown()

        // Per-session counters + cache reset on a new video.
        runner.resetForNewSession()

        let newController = PlaybackController(source: source)
        self.controller = newController

        // Build the session for the initial detector, then spawn the one loop
        // that lives for this source.
        installSession(entry: entry, on: newController)
        spawnDetectionLoop(on: newController)
    }

    // MARK: - Intent 2: swap the detector, keep the source

    /// Swap the active detector to `entry`, keeping the current source.
    ///
    /// Invalidates the cache (old detections came from a different detector),
    /// resets metrics, installs the new session in place (the live detect loop
    /// picks up the new router on its next frame), then re-emits the visible
    /// frame so a paused player shows the new detector's output immediately.
    /// No-op if no source is set.
    public func selectDetector(_ entry: DetectorCatalogEntry) async {
        guard let controller else { return }

        runner.resetForNewSession()

        // In-place session swap. The single detect loop hands each frame to
        // `runner.run(on:)`, which reads `session?.router` every frame, so the
        // next frame routes through the new detector — no stream re-iteration
        // (the single-iteration `AsyncStream` can't be re-consumed; see the
        // type doc).
        installSession(entry: entry, on: controller)

        // Re-emit the visible frame so a paused player re-runs detection under
        // the freshly-selected detector. Same primitive as the pause-emit hook.
        try? await controller.source.seek(to: controller.currentTime)
    }

    // MARK: - Teardown

    /// Tear down the active session. Idempotent.
    ///
    /// Order: cancel detect loop → **drain** (`await task.value`) → clear the
    /// session (+ its pause-emit hook) → `source.invalidate()`. Cancelling the
    /// loop finishes the single-consumer stream; the `await` on `invalidate()`
    /// is what lets the demo release its security scope strictly afterward (the
    /// scope-ordering contract on this type).
    public func teardown() async {
        let task = detectionTask
        detectionTask = nil
        task?.cancel()
        // Cancellation is cooperative; awaiting the task's value blocks until
        // the `for await` loop fully exits. `AsyncStream`'s iterator is
        // cancellation-aware, so this returns promptly.
        await task?.value

        // Drop the session (clears its pause-emit hook) before releasing the
        // source so no stale fire can cross the teardown boundary.
        runner.clearSession()

        let priorSource = controller?.source
        controller = nil
        currentFrame = nil
        runner.resultStore.clear()

        // Detach AVF observers + finish the frame stream. Awaited so the
        // caller can sequence its security-scope release after this returns.
        if let priorSource {
            await priorSource.invalidate()
        }
    }

    // MARK: - Private

    /// Install the catalog session for `entry` via the runner, supplying the
    /// playback-specific seek-based re-emit hook. A `.detector`-tier change
    /// clears the cache; if the source is paused, no frames flow → overlay reads
    /// nil → detections disappear mid-tuning. Seeking to the current time
    /// re-emits a one-shot frame, giving the pipeline a frame to re-run under
    /// the new settings. A `PassthroughRouter` (non-tunable detector) never
    /// fires this — the wiring is a harmless no-op there.
    private func installSession(
        entry: DetectorCatalogEntry,
        on controller: PlaybackController
    ) {
        runner.installSession(entry: entry) { [weak controller] in
            guard let controller else { return }
            let source = controller.source
            let target = controller.currentTime
            Task { try? await source.seek(to: target) }
        }
    }

    /// Spawn the single per-source detect loop. Hands each frame to
    /// `runner.run(on:)` (which reads the live router, so an in-place session
    /// swap takes effect on the next frame) and bridges the source's cumulative
    /// drop/emit counters into the gauge. Cancelled in `teardown`; never
    /// respawned (the stream is single-iteration).
    private func spawnDetectionLoop(on controller: PlaybackController) {
        let runner = self.runner
        let source = controller.source
        detectionTask = Task { [weak self] in
            for await frame in source.frames {
                if Task.isCancelled { break }

                // Source-agnostic per-frame inference + timing.
                await runner.run(on: frame)

                // Bridge the playback-source-specific cumulative counters into
                // the gauge, and publish the just-processed frame for the
                // freeze-from-live affordance (M8·P5). `DetectionMetrics` is
                // `@MainActor` and `currentFrame` is `@MainActor`-isolated, so hop.
                let dropped = source.droppedFrameCount
                let emitted = source.emittedFrameCount
                await MainActor.run {
                    runner.metrics.setDropped(dropped)
                    runner.metrics.setEmitted(emitted)
                    self?.currentFrame = frame
                }
            }
        }
    }
}
