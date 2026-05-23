/// Runs multiple `Detector`s over a single `Frame` and flattens their
/// results.
///
/// Detectors are executed in parallel via `withThrowingTaskGroup`; per-task
/// results are then re-assembled in the same order the detectors were
/// supplied so the output ordering is deterministic and stable across
/// runs. This matters because downstream rendering and dataset code keys
/// off `[Detection]` ordering when there are no other tiebreakers (e.g.,
/// equal confidences, equal labels) — non-determinism here would surface
/// as flicker in overlays and noise in sidecar diffs.
///
/// **Failure mode.** If any detector throws, the pipeline cancels the
/// others and rethrows the first error to surface. Partial results are
/// not returned. Callers that want best-effort behavior should wrap their
/// inner detectors in a forgiving adapter.
///
/// **Concurrency.** `Sendable` via `[any Detector]` (which is `Sendable`
/// because `Detector: Sendable`). The pipeline itself is a stateless
/// `struct` so it crosses actor boundaries freely.
public struct DetectorPipeline: Detector {

    private let detectors: [any Detector]

    public let availability: DetectorAvailability = .available

    public let modelIdentifier: String = "pipeline"

    /// Build a pipeline that fans out across the supplied detectors in
    /// parallel and concatenates their results in input order.
    public init(_ detectors: [any Detector]) {
        self.detectors = detectors
    }

    /// Variadic convenience: `DetectorPipeline(rectDetector, faceDetector)`.
    public init(_ detectors: any Detector...) {
        self.detectors = detectors
    }

    /// Prewarms every wrapped detector in parallel. Returns once all have
    /// completed.
    public func prewarm() async {
        await withTaskGroup(of: Void.self) { group in
            for detector in detectors {
                group.addTask { await detector.prewarm() }
            }
        }
    }

    /// Runs every wrapped detector against `frame` in parallel. The
    /// resulting `[Detection]` is the concatenation of each detector's
    /// output in the order the detectors were supplied to `init` — not
    /// the order tasks happened to complete.
    ///
    /// `Detector`-protocol entry point. Equivalent to calling
    /// `detect(in: frame, cache: nil)` — always runs the detectors, never
    /// consults a cache. Cache-aware callers (playback) should use the
    /// `detect(in:cache:)` overload below.
    public func detect(in frame: Frame) async throws -> [Detection] {
        try await detect(in: frame, cache: nil)
    }

    /// Cache-aware per-frame entry point used by callers that have a
    /// `DetectionCache` to dedupe by `Frame.timestamp` (playback). On
    /// cache hit (`cache.fetch(timestamp: frame.timestamp) != nil`), the
    /// detector dispatch is skipped entirely and the *cached* detections
    /// are returned — semantically distinct from "ran and found nothing"
    /// (which is what a literal `[]` would mean). The overlay reads the
    /// same store on its own tick (see `DetectionLayer`'s `TimelineView`
    /// lookup, which is independent of `append` events), so callers that
    /// ignore the returned value still see the cached entry on screen;
    /// callers that *do* use the value (logging, dataset capture) see the
    /// same source of truth. On cache miss, runs the detectors as today
    /// and writes through to the cache before returning.
    ///
    /// `cache == nil` reproduces the un-cached behavior exactly — every
    /// frame runs through every detector, no skip, no write-through.
    /// Capture call sites that have no cache (or that want every host-
    /// clock timestamp re-detected) pass `nil`.
    ///
    /// Locked decision: feature plan
    /// `plans/features/playback-detection-cache.md`, Phase 2.
    public func detect(
        in frame: Frame,
        cache: (any DetectionCache)?
    ) async throws -> [Detection] {
        // Skip-gate + retrieve: cache hit returns the cached detections
        // immediately with no detector dispatch. Returning the cached
        // value (instead of `[]`) keeps the contract unambiguous: an
        // empty return now strictly means "the detectors ran and found
        // nothing," never "the detectors didn't run."
        if let cache, let cached = await cache.fetch(timestamp: frame.timestamp) {
            return cached.detections
        }

        let detections = try await withThrowingTaskGroup(
            of: (offset: Int, detections: [Detection]).self
        ) { group -> [Detection] in
            for (offset, detector) in detectors.enumerated() {
                group.addTask {
                    let dets = try await detector.detect(in: frame)
                    return (offset, dets)
                }
            }

            var slots: [[Detection]] = Array(repeating: [], count: detectors.count)
            for try await result in group {
                slots[result.offset] = result.detections
            }
            return slots.flatMap { $0 }
        }

        // Write-through on miss so the next visit to this timestamp
        // bucket hits.
        if let cache {
            await cache.append(
                TimestampedDetections(timestamp: frame.timestamp, detections: detections)
            )
        }

        return detections
    }
}
