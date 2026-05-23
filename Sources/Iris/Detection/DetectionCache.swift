import CoreMedia

/// Skip-gate + write-through interface that `DetectorPipeline` uses to
/// avoid re-running detectors on timestamps it has already seen.
///
/// The pipeline consults `contains(timestamp:)` before dispatching its
/// detectors; on hit, the dispatch is skipped entirely. On miss, the
/// pipeline runs the detectors as normal and feeds the result back through
/// `append(_:)` before returning.
///
/// **Why a protocol here.** `DetectorPipeline` lives in
/// `Sources/Iris/Detection/`; the concrete cache (`ResultStore`) lives in
/// `Sources/Iris/Overlay/`. The pipeline must not depend on the overlay
/// folder — Detection → Overlay would invert the natural dependency
/// direction (Overlay reads from the store the pipeline writes; the
/// pipeline shouldn't import the read-side type). This protocol is the
/// minimum surface the pipeline needs, declared inside Detection so the
/// dependency edge runs Overlay → Detection.
///
/// **Concurrency.** Methods are `async` so `@MainActor`-isolated
/// conformers (`ResultStore`) can satisfy them via the usual actor hop —
/// no `@MainActor` on the protocol itself, which would force every
/// conformer onto the main actor.
///
/// Locked decision: feature plan
/// `plans/features/playback-detection-cache.md`, Phase 2.
public protocol DetectionCache: Sendable {

    /// Cheap probe: does the cache hold an entry for the bucket containing
    /// `timestamp`? The pipeline uses this as a skip-gate — a `true` result
    /// means "skip detector dispatch; the cached entry stands."
    func contains(timestamp: CMTime) async -> Bool

    /// Write-through entry point. The pipeline calls this on cache miss
    /// after running its detectors, so the next visit to the same
    /// timestamp bucket hits.
    func append(_ result: TimestampedDetections) async
}
