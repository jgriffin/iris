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
