import CoreMedia

/// Skip-gate + write-through interface that `DetectorPipeline` uses to
/// avoid re-running detectors on timestamps it has already seen.
///
/// The pipeline consults `fetch(timestamp:)` before dispatching its
/// detectors; on hit, the dispatch is skipped entirely and the cached
/// entry's detections are returned directly. On miss, the pipeline runs
/// the detectors as normal and feeds the result back through `append(_:)`
/// before returning. `contains(timestamp:)` is retained as a cheaper
/// probe-only call for callers that don't need the cached value.
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
    /// `timestamp`? A `true` result means "skip detector dispatch; the
    /// cached entry stands." Callers that *also* need the cached value
    /// should use `fetch(timestamp:)` instead, which is a single
    /// hit-or-miss probe that returns the entry.
    func contains(timestamp: CMTime) async -> Bool

    /// Bucket-exact lookup: returns the cached entry for the bucket
    /// containing `timestamp`, or `nil` if no entry has been written to
    /// that bucket. This is *not* the overlay's nearest-neighbor
    /// `lookup(at:stale:)` read path — `fetch` is the bucket-exact probe
    /// the pipeline uses to decide hit-or-miss and retrieve the cached
    /// value in one call, so a cache hit can return the cached detections
    /// directly rather than the semantically ambiguous `[]`.
    func fetch(timestamp: CMTime) async -> TimestampedDetections?

    /// Write-through entry point. The pipeline calls this on cache miss
    /// after running its detectors, so the next visit to the same
    /// timestamp bucket hits.
    func append(_ result: TimestampedDetections) async
}
