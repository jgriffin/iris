import CoreMedia

/// A `[Detection]` paired with the source-frame timestamp that produced
/// it. The `ResultStore` (Phase 2) keys on this so the overlay layer can
/// look up "what was detected at `displayTime`?" via binary search.
///
/// Storing `CMTime` rather than `Double` keeps playback math rational —
/// scrubbing and frame-stepping operate on `CMTime` end-to-end and we
/// avoid an avoidable round-trip through `Double` precision.
public struct TimestampedDetections: Sendable, Hashable {
    /// Presentation timestamp of the source `Frame`.
    public let timestamp: CMTime
    /// Detections produced for that frame. Empty is a real value — it
    /// means "the detector ran and found nothing", as distinct from
    /// "no detector ran" (which is represented by the absence of an
    /// entry in `ResultStore`).
    public let detections: [Detection]

    public init(timestamp: CMTime, detections: [Detection]) {
        self.timestamp = timestamp
        self.detections = detections
    }
}
