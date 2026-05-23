import CoreMedia
import Foundation

/// A `@MainActor`-isolated, persistent, timestamp-keyed cache of
/// `TimestampedDetections`. The overlay layer reads it at draw time via
/// `lookup(at:)` to answer "what was detected at `displayTime`?"; the
/// detector pipeline (Phase 2 of the playback-detection-cache feature)
/// will use `contains(timestamp:)` as a skip-gate to avoid re-running
/// detectors on timestamps it has already seen.
///
/// **Storage.** Keys are *quantized* `CMTime` buckets — one bucket per
/// frame at the configured nominal rate (default 30 fps). Quantization
/// makes floating-point seek targets land in the same bucket as the
/// originally-detected frame, and makes re-detection at the same
/// timestamp idempotent (last write wins).
///
/// **Lookup semantics** (locked decision 11 / nearest-neighbor extension
/// per `plans/features/playback-detection-cache.md`). `lookup(at:)`
/// returns the cache entry whose bucket key is closest to `displayTime`,
/// within an adaptive window of `min(2 × quantization, stale)`. The
/// `stale:` parameter (defaulted from the per-store thresholds) is the
/// hard cap on the search window: a candidate further than `stale` from
/// `displayTime` reads as "detector stalled" and is suppressed.
///
/// **No latency compensation** (locked decision 11). `lookup(at:)` is a
/// pure best-effort time lookup — Iris does not predict forward.
///
/// **No eviction in v1.** M3 fixtures are seconds-long; revisit when M5
/// dataset workflows put long-form footage through the pipeline.
@MainActor
@Observable
public final class ResultStore: DetectionCache {

    /// Quantization unit for timestamp bucketing. Defaults to one frame
    /// at 30 fps (`CMTime(value: 1, timescale: 30)`). Callers driving a
    /// non-30 fps clip should pass the matching unit so adjacent frames
    /// don't collide in a single bucket.
    public let quantization: CMTime

    /// Staleness threshold for live-capture `lookup(at:)` calls — the
    /// `lookup` default when `stale:` is not supplied. 500 ms matches the
    /// locked decision: live overlays older than this read as "detector
    /// stalled" and are suppressed.
    public var liveStalenessThreshold: CMTime = CMTime(value: 500, timescale: 1000)

    /// Staleness threshold for playback `lookup(at:)` calls. Pass via the
    /// `stale:` parameter when the store is driven by an `AVPlayer` clock.
    /// 2 s matches the locked decision: scrub gaps and seek-driven dead
    /// zones in playback are wider than live capture's tolerance.
    public var playbackStalenessThreshold: CMTime = CMTime(value: 2, timescale: 1)

    /// Bucketed storage. Key is the quantized `CMTime` for an asset-time
    /// bucket; value is the detections produced for that bucket. `CMTime`
    /// is `Hashable` on modern Apple platforms, so direct use as a
    /// dictionary key is fine.
    private var entries: [CMTime: TimestampedDetections] = [:]

    public init(quantization: CMTime = CMTime(value: 1, timescale: 30)) {
        self.quantization = quantization
    }

    /// Insert `result` at its quantized bucket. Idempotent for the same
    /// bucket — re-detection at the same timestamp overwrites. No size
    /// cap, no eviction in v1.
    public func append(_ result: TimestampedDetections) {
        let key = bucket(result.timestamp)
        entries[key] = result
    }

    /// Empty the cache (e.g. when the source changes).
    public func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    /// `DetectionCache` conformance — the M4 tuning channel's
    /// detector-tier invalidation hook. Forwards to `clear()` so there's
    /// one storage-mutation site to reason about. The async signature is
    /// the protocol's requirement (matches `append(_:)` / `fetch(_:)`);
    /// the body itself is a synchronous `@MainActor` call.
    public func invalidateAll() {
        clear()
    }

    /// Nearest-neighbor cache entry to `displayTime`, within an adaptive
    /// window of `min(2 × quantization, stale)`. Returns `[]` if no
    /// bucket falls inside that window. `stale` (when omitted) defaults
    /// to `liveStalenessThreshold`; playback consumers pass
    /// `playbackStalenessThreshold`.
    public func lookup(at displayTime: CMTime, stale: CMTime? = nil) -> [Detection] {
        guard !entries.isEmpty else { return [] }
        let hardCap = stale ?? liveStalenessThreshold
        let adaptive = CMTimeMultiplyByRatio(quantization, multiplier: 2, divisor: 1)
        let window = CMTimeMinimum(adaptive, hardCap)

        var best: TimestampedDetections?
        var bestGap: CMTime = window  // candidates must beat this to win
        var foundExact = false

        for (key, value) in entries {
            let gap = CMTimeAbsoluteValue(key - displayTime)
            if gap > window { continue }
            if best == nil || gap < bestGap {
                best = value
                bestGap = gap
                foundExact = (gap == .zero)
            } else if gap == bestGap, !foundExact {
                // Tie: keep the first deterministic winner; dict iteration
                // order isn't stable, but ties within a 1-bucket gap are
                // semantically equivalent (same quantized frame).
                _ = key
            }
        }
        return best?.detections ?? []
    }

    /// Cheap probe: does the cache hold an entry for the bucket containing
    /// `timestamp`? Used by callers that don't need the cached value
    /// (e.g. a write-only sink deciding whether to skip its detector
    /// dispatch when no read is required). Bucket-aware — distinct
    /// floating-point timestamps within the same quantization bucket all
    /// return the same answer. Equivalent to `fetch(timestamp:) != nil`
    /// but avoids materializing the entry.
    public func contains(timestamp: CMTime) -> Bool {
        entries[bucket(timestamp)] != nil
    }

    /// Bucket-exact lookup: returns the cached `TimestampedDetections`
    /// for the bucket containing `timestamp`, or `nil` if no entry has
    /// been written to that bucket. Bucket-aware — any timestamp within
    /// the same quantization bucket as a prior `append(_:)` returns that
    /// entry. Used by `DetectorPipeline.detect(in:cache:)` as the skip-
    /// gate-and-fetch probe, so a cache hit can return the cached
    /// detections directly rather than `[]`.
    ///
    /// This is *not* the overlay's nearest-neighbor read path — use
    /// `lookup(at:stale:)` for that. `fetch` is strictly bucket-exact:
    /// a timestamp two buckets away from any cached entry returns `nil`,
    /// even though `lookup(at:)` may still surface a neighbor inside its
    /// adaptive window.
    public func fetch(timestamp: CMTime) -> TimestampedDetections? {
        entries[bucket(timestamp)]
    }

    // MARK: - Private

    /// Round `t` to the nearest multiple of `quantization`. The returned
    /// `CMTime` uses `quantization.timescale` so equality / hashing across
    /// inserts and lookups is stable (two callers passing semantically
    /// equal bucket times always produce the same `CMTime` value).
    private func bucket(_ t: CMTime) -> CMTime {
        let unit = quantization.seconds
        guard unit > 0 else { return t }
        let index = (t.seconds / unit).rounded()
        return CMTime(
            seconds: index * unit,
            preferredTimescale: quantization.timescale
        )
    }
}
