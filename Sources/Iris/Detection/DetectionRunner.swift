import Foundation
import Observation
import os

// MARK: - DetectionRunner

/// The **source-agnostic detection core**: the `ResultStore` + `DetectionMetrics`
/// it owns and resets, the `ActiveDetectorSession` it builds from a catalog
/// entry, and the per-frame "run the pipeline, time it, record the gauge" unit.
///
/// **Why this is its own type (M8·P1).** This core has two consumers now: the
/// `PlaybackDetectionCoordinator` runs it in a per-source detect loop over a
/// `Frame` *stream*; the image inspector runs it **one-shot** on a single still
/// (load, detect, swap-and-re-detect). Both need the same cache/metrics/session
/// state and the same per-frame inference; only the *driving* differs (a stream
/// loop vs. a one-shot call) and the *re-emit strategy* differs (seek to re-run
/// while paused vs. re-detect the held frame). Per the single-target doctrine,
/// the split was deferred until that second consumer materialized — it now has,
/// so the loop+cache+metrics+session core lifts out here and each consumer
/// composes it (`plans/features/M8.md` §P1).
///
/// **What stays with the consumer.** The frame *driving* (stream iteration or
/// one-shot), any source lifecycle (a `PlaybackController`, a held image), the
/// source-specific counters (`PlaybackSource.droppedFrameCount` /
/// `emittedFrameCount`), and the `onDetectorTierChange` re-emit closure — which
/// is consumer-specific and injected via `installSession(entry:onTierChange:)`.
///
/// **Detector swap is an in-place session swap.** `installSession` replaces the
/// active `session` (and its router) in place; a streamed consumer's loop reads
/// `session?.router` on every frame, so the freshly-selected detector routes the
/// next frame with no stream re-iteration. The hot-swap contract itself lives in
/// `DetectorPipeline.detect(in:cache:tuning:)`, which reads `router.currentDetector`.
///
/// **Concurrency.** `@MainActor @Observable` — it fronts the @MainActor cache /
/// metrics / session state in the project's SwiftUI-shaped idiom. The per-frame
/// `run(on:)` is `nonisolated async` so the heavy inference runs off the main
/// actor (a streamed consumer calls it from its detached loop); it hops to the
/// main actor only for the cheap router read and the metrics record.
@MainActor
@Observable
public final class DetectionRunner {

    // MARK: - Outputs the demo binds its library views to

    /// Detection cache. → `DetectionLayer(store:)` + `DetectionInspector(store:)`.
    /// Held for the runner's lifetime; `resetForNewSession()` clears it on a
    /// detector swap or new source.
    public let resultStore: ResultStore

    /// Best-effort pipeline gauge. → `DetectionMetricsView(metrics:)`.
    /// `resetForNewSession()` zeroes it on a detector swap or new source.
    public let metrics: DetectionMetrics

    /// The active detector session. → `.router` for `DetectionLayer(tuning:)`,
    /// `.settingsView` for the tuning sheet. `nil` before the first
    /// `installSession` and after `clearSession`. Swapped in place — a streamed
    /// consumer's loop reads `session?.router` each frame, so the swap takes
    /// effect on the next frame without re-iterating the stream.
    public private(set) var session: ActiveDetectorSession?

    // MARK: - Stored

    /// Cache-/tuning-aware pipeline. Empty detector array — detection comes from
    /// the session's router (`router.currentDetector`), which the pipeline runs
    /// in place of its own array (the hot-swap seam).
    @ObservationIgnored private let pipeline = DetectorPipeline([])

    @ObservationIgnored private let logger =
        Logger(subsystem: "iris.detection", category: "detection-runner")

    // MARK: - Init

    /// Build a runner holding the supplied cache + metrics. Both default to
    /// fresh instances; a consumer can inject its own to share them with other
    /// UI before a session is installed.
    public init(
        resultStore: ResultStore = .init(),
        metrics: DetectionMetrics = .init()
    ) {
        self.resultStore = resultStore
        self.metrics = metrics
    }

    // MARK: - Session management

    /// Build the catalog session for `entry` against the runner's cache, wire
    /// its `onDetectorTierChange` hook to the consumer-supplied closure, and
    /// install it as the active `session`. Does **not** touch any drive loop — a
    /// streamed consumer reads the live `session?.router` each frame, so
    /// installing a new session is the whole of a detector swap.
    ///
    /// `onTierChange` is the consumer's re-emit strategy: playback seeks to the
    /// current time to re-run detection while paused; the image inspector
    /// re-detects its held frame. A `PassthroughRouter` (non-tunable detector)
    /// never fires it, so passing a closure is a harmless no-op there.
    public func installSession(
        entry: DetectorCatalogEntry,
        onTierChange: (@Sendable @MainActor () -> Void)?
    ) {
        // Clear the prior session's hook so a late fire can't cross the swap.
        session?.router.onDetectorTierChange = nil

        // `cache: resultStore` means a `.detector`-tier knob change invalidates
        // the cache so the next inference produces fresh detections under the
        // new settings.
        let newSession = entry.makeSession(resultStore)
        newSession.router.onDetectorTierChange = onTierChange
        self.session = newSession
    }

    /// Drop the active session, clearing its self-emit hook first so no stale
    /// fire can cross a teardown boundary. Idempotent.
    public func clearSession() {
        session?.router.onDetectorTierChange = nil
        session = nil
    }

    /// Zero the metrics gauge and invalidate the cache. Called on a new source
    /// or a detector swap so counts + detections are per-session.
    public func resetForNewSession() {
        metrics.reset()
        resultStore.invalidateAll()
    }

    // MARK: - Per-frame inference

    /// Run `frame` through the pipeline against the live session router, writing
    /// detections through to the cache and timing the inference into the gauge.
    /// The single per-frame unit both consumers share.
    ///
    /// `nonisolated` so a streamed consumer can call it from its off-main detect
    /// loop and keep the heavy inference off the main actor; it hops to the main
    /// actor only for the router read and the metrics record. A detect failure
    /// is logged and swallowed — Iris detection is best-effort.
    public nonisolated func run(on frame: Frame) async {
        // Read the live router on the main actor so a mid-stream detector swap
        // (in-place `installSession`) routes this frame through the new detector.
        // `nil` before a session exists leaves the pipeline's own (empty)
        // detector array, a safe no-op.
        let router = await MainActor.run { self.session?.router }
        do {
            let clock = ContinuousClock()
            let start = clock.now
            _ = try await pipeline.detect(in: frame, cache: resultStore, tuning: router)
            let elapsed = clock.now - start
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            await MainActor.run { metrics.recordInference(seconds: seconds) }
        } catch {
            logger.error(
                "detect failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
