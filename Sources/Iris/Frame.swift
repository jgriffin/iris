import CoreMedia
import CoreVideo
import ImageIO

/// A single frame from any source. Sendable across actors because the
/// underlying CVPixelBuffer is treated as immutable from the moment it's
/// wrapped here — producers must not mutate the buffer in place after
/// constructing a Frame, and consumers must not mutate it ever. Buffer
/// retention/release is handled by ARC on the CVPixelBuffer reference; the
/// buffer's IOSurface keeps it alive across actor hops with zero copies.
///
/// Invariants justifying @unchecked Sendable:
///   1. `pixelBuffer` is immutable after Frame construction.
///   2. `pixelBuffer` is IOSurface-backed (both producers guarantee this).
///   3. All other fields are value types or enums that are themselves Sendable.
public struct Frame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer

    /// Presentation timestamp. **Semantics are source-defined**, not absolute:
    ///
    /// - **Capture** (`CaptureSession`): host-clock time pulled from
    ///   `CMSampleBuffer.presentationTimeStamp` — relative to the AVF
    ///   capture clock, monotonically increasing with wall time.
    /// - **Playback** (`PlaybackSource`): asset time pulled from
    ///   `AVPlayerItem.currentTime()` — relative to the asset's own
    ///   timeline, starts at `.zero`, advances with playback (so seeking
    ///   makes it non-monotonic by design).
    /// - **Mock** (`MockSource`): whatever the test supplies.
    ///
    /// The pipeline contract is per-source consistency: a `Frame` and the
    /// `[Detection]` derived from it carry the *same* clock, so
    /// `ResultStore` lookups stay internally coherent regardless of source.
    /// Mixing frames or lookups across sources within a single pipeline is
    /// a live concern tracked in [`plans/QUESTIONS.md`].
    public let timestamp: CMTime
    public let orientation: CGImagePropertyOrientation
    public let source: SourceKind
    public let format: PixelFormat
    public let dimensions: CGSize

    public init(
        pixelBuffer: CVPixelBuffer,
        timestamp: CMTime,
        orientation: CGImagePropertyOrientation,
        source: SourceKind,
        format: PixelFormat,
        dimensions: CGSize
    ) {
        self.pixelBuffer = pixelBuffer
        self.timestamp = timestamp
        self.orientation = orientation
        self.source = source
        self.format = format
        self.dimensions = dimensions
    }

    /// Presentation timestamp as seconds. Convenience over `timestamp`; storage
    /// stays rational (`CMTime`) for playback math.
    public var seconds: Double { CMTimeGetSeconds(timestamp) }
}
