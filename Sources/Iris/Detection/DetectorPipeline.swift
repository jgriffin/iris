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
        try await detect(in: frame, cache: nil, tuning: nil)
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
    ///
    /// Source-stable shim onto `detect(in:cache:tuning:)`. Pre-M4
    /// call sites pass `cache:` only; the new `tuning:` parameter
    /// lands on the four-arg overload below.
    public func detect(
        in frame: Frame,
        cache: (any DetectionCache)?
    ) async throws -> [Detection] {
        try await detect(in: frame, cache: cache, tuning: nil)
    }

    /// Cache- + tuning-aware entry point used by the M4 channel.
    ///
    /// **Tuning routing.** When `tuning` is non-nil:
    ///
    ///   1. If `await tuning.currentDetector` returns a non-nil
    ///      detector, the pipeline runs that detector *instead* of
    ///      its own `detectors` array. This is how the hot-swap
    ///      doctrine surfaces: `TuningModel` replaces the detector
    ///      reference internally, and the pipeline picks up the new
    ///      instance on the next call. Falls back to the
    ///      pipeline's own detector array when the router has none
    ///      (e.g. a filter-only router).
    ///   2. After the detection list is assembled — *either* from a
    ///      cache hit *or* from a fresh inference — the optional
    ///      `await tuning.transform` closure is applied to the
    ///      output. This is intentionally on the *output* path,
    ///      not the write-through path: the cache stays a record
    ///      of what the detector actually produced (not what
    ///      passed the transform), so filter-tier knob changes can
    ///      re-apply without re-running inference.
    ///
    /// `tuning == nil` reproduces the pre-M4 behavior exactly — the
    /// pipeline's own detectors run, no output filter, no
    /// hot-swap.
    public func detect(
        in frame: Frame,
        cache: (any DetectionCache)?,
        tuning: (any TuningRouter)?
    ) async throws -> [Detection] {
        // Snapshot the tuning router's two read-side properties up
        // front. Both are `@MainActor`-isolated; doing the hops here
        // (once per call) is cheaper than re-hopping at each use site,
        // and gives us a stable view through the rest of the function.
        let routerDetector: (any Detector)?
        let outputTransform: (@Sendable ([Detection]) -> [Detection])?
        if let tuning {
            (routerDetector, outputTransform) = await MainActor.run {
                (tuning.currentDetector, tuning.transform)
            }
        } else {
            routerDetector = nil
            outputTransform = nil
        }

        // Skip-gate + retrieve: cache hit returns the cached detections
        // immediately with no detector dispatch. Returning the cached
        // value (instead of `[]`) keeps the contract unambiguous: an
        // empty return now strictly means "the detectors ran and found
        // nothing," never "the detectors didn't run." Apply the
        // tuning transform on the *output* of the cache hit so
        // filter-tier knob changes show through on already-cached
        // frames without re-running inference.
        if let cache, let cached = await cache.fetch(timestamp: frame.timestamp) {
            return applyTransform(outputTransform, to: cached.detections)
        }

        // Pick the detector set: tuning router's current detector if
        // present (post-hot-swap), else the pipeline's own array.
        let effectiveDetectors: [any Detector] = {
            if let routerDetector { return [routerDetector] }
            return detectors
        }()

        let detections = try await withThrowingTaskGroup(
            of: (offset: Int, detections: [Detection]).self
        ) { group -> [Detection] in
            for (offset, detector) in effectiveDetectors.enumerated() {
                group.addTask {
                    let dets = try await detector.detect(in: frame)
                    return (offset, dets)
                }
            }

            var slots: [[Detection]] = Array(repeating: [], count: effectiveDetectors.count)
            for try await result in group {
                slots[result.offset] = result.detections
            }
            return slots.flatMap { $0 }
        }

        // Write-through on miss so the next visit to this timestamp
        // bucket hits. The cached payload is the *unfiltered* output —
        // see the doc comment above for why.
        if let cache {
            await cache.append(
                TimestampedDetections(timestamp: frame.timestamp, detections: detections)
            )
        }

        return applyTransform(outputTransform, to: detections)
    }

    /// Apply an optional output-stage transform. Pulled out so the
    /// cache-hit and cache-miss return paths share one site, and so
    /// the no-transform case is a single identity reference (no
    /// allocation for `transform == nil`).
    private func applyTransform(
        _ transform: (@Sendable ([Detection]) -> [Detection])?,
        to detections: [Detection]
    ) -> [Detection] {
        guard let transform else { return detections }
        return transform(detections)
    }
}
