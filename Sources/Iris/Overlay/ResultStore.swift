import CoreMedia
import Foundation

/// A `@MainActor`-isolated sorted ring buffer of `TimestampedDetections`,
/// keyed by `CMTime`. The overlay layer reads it at draw time via
/// `lookup(at:)` to answer "what was detected at `displayTime`?" in
/// O(log n).
///
/// **Staleness contract** (locked decision 13 in
/// `explorations/display-pipeline-architecture/RECOMMENDATIONS.md`).
/// `lookup(at:)` returns `[]` when the most-recent candidate's timestamp
/// trails `displayTime` by more than the staleness threshold. This surfaces
/// "detector is broken" as "no boxes" rather than as a sticky last-known
/// overlay. Defaults are 500 ms for live capture, 2 s for playback; apps
/// override the per-store thresholds or pass `stale:` per call.
///
/// **No latency compensation** (locked decision 11). `lookup(at:)` is a
/// pure best-effort time lookup — Iris does not predict forward. Apps that
/// want zero-lag overlays predict ahead of `append`.
@MainActor
@Observable
public final class ResultStore {

    /// Maximum number of `TimestampedDetections` retained. Oldest entries
    /// are evicted from the front when `append` would exceed this.
    public private(set) var capacity: Int

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

    private var buffer: [TimestampedDetections] = []

    public init(capacity: Int = 30) {
        self.capacity = capacity
    }

    /// Insert `result` in timestamp-sorted order. O(log n) insertion point;
    /// O(n) array shift for the insertion itself. When the buffer exceeds
    /// `capacity`, the oldest entries are dropped from the front. Synchronous
    /// — no `Task` spawn (locked decision: no per-frame `Task`).
    public func append(_ result: TimestampedDetections) {
        let idx = upperBound(of: result.timestamp)
        buffer.insert(result, at: idx)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    /// Drop every buffered result. Capacity is preserved. Call from
    /// `PlaybackSession.willSeek` so post-seek frames don't overlay
    /// pre-seek detections.
    public func clear() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// Most-recent buffered detections whose timestamp is `<= displayTime`.
    /// Returns `[]` if the buffer is empty, if `displayTime` precedes every
    /// entry, or if the candidate trails `displayTime` by more than the
    /// staleness threshold (`stale` if supplied, else
    /// `liveStalenessThreshold`). O(log n) via binary search.
    public func lookup(at displayTime: CMTime, stale: CMTime? = nil) -> [Detection] {
        guard !buffer.isEmpty else { return [] }
        let upper = upperBound(of: displayTime)
        guard upper > 0 else { return [] }
        let candidate = buffer[upper - 1]
        let threshold = stale ?? liveStalenessThreshold
        if displayTime - candidate.timestamp > threshold { return [] }
        return candidate.detections
    }

    // MARK: - Private

    /// Binary-search the first index `i` where `buffer[i].timestamp > timestamp`.
    /// Equivalent to C++'s `std::upper_bound`. Used by both `append` (insertion
    /// point that preserves FIFO order for equal timestamps) and `lookup`
    /// (`i - 1` is the candidate with the greatest `timestamp <= displayTime`).
    private func upperBound(of timestamp: CMTime) -> Int {
        var lo = 0
        var hi = buffer.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if buffer[mid].timestamp <= timestamp {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}
