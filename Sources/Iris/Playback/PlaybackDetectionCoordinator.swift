import Foundation
import Observation
import os

// MARK: - PlaybackDetectionCoordinator

/// Owns the playback **detection-session orchestration** the two demos used
/// to duplicate verbatim: the detect loop and its lifecycle, the
/// `ResultStore` + `DetectionMetrics` it resets at the right moments, the
/// `ActiveDetectorSession` it builds from a catalog entry, the self-wired
/// `onDetectorTierChange` pause-emit hook, and the `PlaybackController`
/// lifecycle + ordered teardown.
///
/// **Why this lives in `Playback/`.** The coordinator is playback-coupled —
/// the pause-emit hook needs a `PlaybackController` + `seek` to re-emit the
/// visible frame so a `.detector`-tier change shows through while paused.
/// The detect-loop + cache + metrics core is genuinely source-agnostic, but
/// it is **deliberately not pre-split** into a `Detection/`-side runner;
/// per the single-target doctrine, lifting it out later is a non-breaking
/// change, and there is no capture-side detection consumer yet to justify
/// the seam (`plans/features/playback-detection-coordinator.md` §Opens).
///
/// **Detector swap is an in-place router swap — NOT a loop respawn.**
/// `PlaybackSource.frames` is a *single-iteration* `AsyncStream`: cancelling
/// the consuming task **finishes the stream**, so a second `for await` over
/// the same `frames` receives nothing (verified empirically; this is plain
/// `AsyncStream` semantics, not a `PlaybackSource` quirk). The coordinator
/// therefore spawns **one** detect loop per source, alive for the source's
/// lifetime, and a detector swap replaces the active `session` (and its
/// router) *in place*. The loop reads the coordinator's current router on
/// every frame and hands it to `DetectorPipeline.detect(in:cache:tuning:)`,
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
/// hops to read the current router + record metrics.
@MainActor
@Observable
public final class PlaybackDetectionCoordinator {

    // MARK: - Outputs the demo binds its library views to

    /// Detection cache. → `DetectionLayer(store:)` + `DetectionInspector(store:)`.
    /// Held for the coordinator's lifetime; `invalidateAll()` clears it on a
    /// detector swap or new source.
    public let resultStore: ResultStore

    /// Best-effort pipeline gauge. → `DetectionMetricsView(metrics:)`.
    /// `reset()` on a detector swap or new source.
    public let metrics: DetectionMetrics

    /// The active playback controller, created per source. → `Scrubber(model:)`
    /// + `PlaybackView(source: controller.source)`. `nil` before the first
    /// `setSource` and after `teardown`.
    public private(set) var controller: PlaybackController?

    /// The active detector session. → `.router` for `DetectionLayer(tuning:)`,
    /// `.settingsView` for the tuning sheet. `nil` before the first `setSource`
    /// and after `teardown`. Swapped in place by `selectDetector` — the detect
    /// loop reads `session?.router` on every frame, so the swap takes effect on
    /// the next frame without re-iterating the stream.
    public private(set) var session: ActiveDetectorSession?

    // MARK: - Stored

    /// The single per-source detect loop. Spawned in `setSource`, cancelled in
    /// `teardown`. Never respawned for a detector swap (the stream is
    /// single-iteration — see the type doc).
    @ObservationIgnored private var detectionTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "iris.playback", category: "detection-coordinator")

    // MARK: - Init

    /// Build a coordinator holding the supplied cache + metrics. Both default
    /// to fresh instances; the demo can inject its own if it needs to share
    /// them with other UI before a source is set.
    public init(
        resultStore: ResultStore = .init(),
        metrics: DetectionMetrics = .init()
    ) {
        self.resultStore = resultStore
        self.metrics = metrics
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
        metrics.reset()
        resultStore.invalidateAll()

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

        resultStore.invalidateAll()
        metrics.reset()

        // In-place router swap. The single detect loop reads `session?.router`
        // every frame, so the next frame routes through the new detector — no
        // stream re-iteration (the single-iteration `AsyncStream` can't be
        // re-consumed; see the type doc).
        installSession(entry: entry, on: controller)

        // Re-emit the visible frame so a paused player re-runs detection under
        // the freshly-selected detector. Same primitive as the pause-emit hook.
        try? await controller.source.seek(to: controller.currentTime)
    }

    // MARK: - Teardown

    /// Tear down the active session. Idempotent.
    ///
    /// Order: cancel detect loop → **drain** (`await task.value`) → clear the
    /// pause-emit hook → `source.invalidate()`. Cancelling the loop finishes
    /// the single-consumer stream; the `await` on `invalidate()` is what lets
    /// the demo release its security scope strictly afterward (the
    /// scope-ordering contract on this type).
    public func teardown() async {
        let task = detectionTask
        detectionTask = nil
        task?.cancel()
        // Cancellation is cooperative; awaiting the task's value blocks until
        // the `for await` loop fully exits. `AsyncStream`'s iterator is
        // cancellation-aware, so this returns promptly.
        await task?.value

        // Defensive: drop the pause-emit hook before releasing the session so
        // no stale fire can cross the teardown boundary.
        session?.router.onDetectorTierChange = nil

        let priorSource = controller?.source
        controller = nil
        session = nil
        resultStore.clear()

        // Detach AVF observers + finish the frame stream. Awaited so the
        // caller can sequence its security-scope release after this returns.
        if let priorSource {
            await priorSource.invalidate()
        }
    }

    // MARK: - Private

    /// Build the catalog session for `entry`, wire its self-emit hook to
    /// `controller`, and install it as the active `session`. Does **not** touch
    /// the detect loop — the loop reads the live `session?.router` each frame,
    /// so installing a new session is the whole of a detector swap.
    private func installSession(
        entry: DetectorCatalogEntry,
        on controller: PlaybackController
    ) {
        // Clear the prior session's hook so a late fire can't cross the swap.
        session?.router.onDetectorTierChange = nil

        // `cache: resultStore` (passed into `makeSession`) means a
        // `.detector`-tier knob change invalidates the playback cache so the
        // next decode produces fresh detections under the new settings.
        let newSession = entry.makeSession(resultStore)

        // Self-wired pause-emit hook. A `.detector`-tier change clears the
        // cache; if the source is paused, no frames flow → overlay reads nil →
        // detections disappear mid-tuning. Seeking to the current time re-emits
        // a one-shot frame, giving the pipeline a frame to re-run under the new
        // settings. A `PassthroughRouter` (non-tunable detector) never fires
        // this — the wiring is a harmless no-op there.
        newSession.router.onDetectorTierChange = { [weak controller] in
            guard let controller else { return }
            let source = controller.source
            let target = controller.currentTime
            Task { try? await source.seek(to: target) }
        }

        self.session = newSession
    }

    /// Spawn the single per-source detect loop. Reads the coordinator's current
    /// router (`session?.router`) on each frame and runs the pipeline against
    /// it — so an in-place `installSession` swap takes effect on the next
    /// frame. Cancelled in `teardown`; never respawned (the stream is
    /// single-iteration).
    private func spawnDetectionLoop(on controller: PlaybackController) {
        let store = resultStore
        let pipeline = DetectorPipeline([])
        let source = controller.source
        let metrics = self.metrics
        detectionTask = Task { [weak self] in
            for await frame in source.frames {
                if Task.isCancelled { break }
                // Read the live router on the main actor so a mid-stream
                // detector swap (in-place `installSession`) routes the next
                // frame through the new detector. `nil` before a session
                // exists (shouldn't happen — the loop is spawned after the
                // first `installSession`) leaves the pipeline's own (empty)
                // detector array, which is a safe no-op.
                let router = await MainActor.run { self?.session?.router }
                do {
                    // Time the inference for the best-effort gauge.
                    // `DetectionMetrics` is `@MainActor`, so record on the main
                    // actor; the cumulative source counters are bridged in.
                    let clock = ContinuousClock()
                    let start = clock.now
                    _ = try await pipeline.detect(in: frame, cache: store, tuning: router)
                    let elapsed = clock.now - start
                    let seconds = Double(elapsed.components.seconds)
                        + Double(elapsed.components.attoseconds) / 1e18
                    let dropped = source.droppedFrameCount
                    let emitted = source.emittedFrameCount
                    await MainActor.run {
                        metrics.recordInference(seconds: seconds)
                        metrics.setDropped(dropped)
                        metrics.setEmitted(emitted)
                    }
                } catch {
                    self?.logger.error(
                        "detect failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
    }
}
