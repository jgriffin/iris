import CoreGraphics

/// Converts Vision-normalized geometry (bottom-left origin, `[0, 1]`) into
/// view-space geometry (top-left origin, pixels). Iris centralizes this
/// single Y-flip + aspect-fit math behind one protocol so the overlay
/// layer never re-derives it per call site.
///
/// **Two locked backends.**
/// - `PreviewLayerConverter` (iOS only) holds an
///   `AVCaptureVideoPreviewLayer` reference and delegates to
///   `layerRectConverted(fromMetadataOutputRect:)` /
///   `layerPointConverted(fromCaptureDevicePoint:)` — AVF handles the
///   `videoGravity`-aware letterbox math and front-camera mirroring
///   internally.
/// - `PlayerLayerConverter` (iOS + macOS) carries an `AVPlayerLayer`
///   reference and performs explicit aspect-fit math against
///   `playerLayer.videoRect`, with the Y-flip at `1 - y - h`.
///
/// **`in videoRect:` semantics.** The `videoRect` argument is the
/// on-screen rect that the video pixels occupy after `videoGravity =
/// .resizeAspect` letterbox/pillarbox. For `PlayerLayerConverter` this is
/// `AVPlayerLayer.videoRect`. For `PreviewLayerConverter` the layer's own
/// `layerRectConverted` already accounts for letterbox internally; the
/// `videoRect` argument is unused (kept for protocol symmetry).
///
/// **Concurrency.** The protocol is `Sendable` so existentials can cross
/// isolation boundaries. Concrete conformers that hold `CALayer`-backed
/// AVF references (`PreviewLayerConverter`, `PlayerLayerConverter`) are
/// `@unchecked Sendable` with a documented invariant — see each type's
/// header.
public protocol NormalizedGeometryConverting: Sendable {

    /// Convert a Vision-normalized rect (bottom-left origin, `[0, 1]`) into
    /// a view-space rect (top-left origin, pixels) suitable for SwiftUI
    /// drawing.
    ///
    /// - Parameters:
    ///   - rect: Normalized rect in `[0, 1]` source-frame coordinates,
    ///     Vision-native (bottom-left) origin.
    ///   - videoRect: The on-screen rect that the video pixels occupy
    ///     after aspect-fit letterbox/pillarbox. Ignored by converters
    ///     that delegate to AVF (`PreviewLayerConverter`).
    /// - Returns: Pixel-space rect in the host view's coordinate system,
    ///   top-left origin.
    func viewRect(forNormalized rect: CGRect, in videoRect: CGRect) -> CGRect

    /// Convert a Vision-normalized point (bottom-left origin, `[0, 1]`)
    /// into a view-space point (top-left origin, pixels).
    ///
    /// - Parameters:
    ///   - point: Normalized point in `[0, 1]` source-frame coordinates,
    ///     Vision-native (bottom-left) origin.
    ///   - videoRect: The on-screen rect that the video pixels occupy
    ///     after aspect-fit letterbox/pillarbox. Ignored by converters
    ///     that delegate to AVF (`PreviewLayerConverter`).
    /// - Returns: Pixel-space point in the host view's coordinate system,
    ///   top-left origin.
    func viewPoint(forNormalized point: CGPoint, in videoRect: CGRect) -> CGPoint
}
