#if os(iOS)

import CoreMedia

/// A capture format the device supports: dimensions, frame-rate range, and
/// pixel format. Used by `CaptureSession.setPreferredFormat(_:)` (deferred
/// past M1) and by callers introspecting `CameraDevice` capabilities.
public struct CaptureFormat: Sendable, Hashable {
    public let dimensions: CMVideoDimensions
    public let minFrameRate: Double
    public let maxFrameRate: Double
    public let pixelFormat: PixelFormat

    public init(
        dimensions: CMVideoDimensions,
        minFrameRate: Double,
        maxFrameRate: Double,
        pixelFormat: PixelFormat
    ) {
        self.dimensions = dimensions
        self.minFrameRate = minFrameRate
        self.maxFrameRate = maxFrameRate
        self.pixelFormat = pixelFormat
    }

    public static func == (lhs: CaptureFormat, rhs: CaptureFormat) -> Bool {
        lhs.dimensions.width == rhs.dimensions.width
            && lhs.dimensions.height == rhs.dimensions.height
            && lhs.minFrameRate == rhs.minFrameRate
            && lhs.maxFrameRate == rhs.maxFrameRate
            && lhs.pixelFormat == rhs.pixelFormat
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(dimensions.width)
        hasher.combine(dimensions.height)
        hasher.combine(minFrameRate)
        hasher.combine(maxFrameRate)
        hasher.combine(pixelFormat)
    }
}

#endif
