import CoreVideo

/// Pixel format of a `Frame`'s backing `CVPixelBuffer`.
///
/// The Iris default is `yuv420BiPlanarFull` — Vision-native, IOSurface-backed,
/// ~12 MB per 4K frame. `bgra8` stays available as an opt-in for paths that
/// need direct CPU access in a single packed plane.
public enum PixelFormat: Sendable, Hashable {
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` — the Iris default.
    case yuv420BiPlanarFull

    /// `kCVPixelFormatType_32BGRA` — opt-in.
    case bgra8

    /// Underlying `OSType` for AVF configuration.
    internal var osType: OSType {
        switch self {
        case .yuv420BiPlanarFull: return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case .bgra8: return kCVPixelFormatType_32BGRA
        }
    }
}
