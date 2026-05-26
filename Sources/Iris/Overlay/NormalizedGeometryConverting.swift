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
///   internally. The capture path has no SwiftUI-measured container size:
///   the layer's own bounds + `videoGravity` are authoritative, so the
///   converter ignores any externally-supplied size.
/// - `VideoGeometry` (iOS + macOS) is a pure value type that places
///   upright-source-normalized coordinates into a SwiftUI-measured display
///   box (aspect-fit letterbox/pillarbox or aspect-fill crop) and applies
///   the Y-flip. It is the single authority for the playback path; it needs
///   no AVF layer, only the measured container size and the upright content
///   size.
///
/// **No `videoRect` parameter.** Box geometry is resolved *before* a
/// converter is built — `VideoGeometry` derives its own `displayRect` from
/// `containerSize` + `contentSize`, and `PreviewLayerConverter` reads it off
/// the live AVF layer. Neither needs the caller to thread an on-screen video
/// rect through each conversion call.
///
/// **Concurrency.** The protocol is `Sendable` so existentials can cross
/// isolation boundaries. The pure-value `VideoGeometry` is trivially
/// `Sendable`; `PreviewLayerConverter` holds a `CALayer`-backed AVF
/// reference and is `@unchecked Sendable` with a documented invariant — see
/// its header.
public protocol NormalizedGeometryConverting: Sendable {

    /// Convert a Vision-normalized rect (bottom-left origin, `[0, 1]`) into
    /// a view-space rect (top-left origin, pixels) suitable for SwiftUI
    /// drawing.
    ///
    /// - Parameter rect: Normalized rect in `[0, 1]` source-frame
    ///   coordinates, Vision-native (bottom-left) origin.
    /// - Returns: Pixel-space rect in the host view's coordinate system,
    ///   top-left origin.
    func viewRect(forNormalized rect: CGRect) -> CGRect

    /// Convert a Vision-normalized point (bottom-left origin, `[0, 1]`)
    /// into a view-space point (top-left origin, pixels).
    ///
    /// - Parameter point: Normalized point in `[0, 1]` source-frame
    ///   coordinates, Vision-native (bottom-left) origin.
    /// - Returns: Pixel-space point in the host view's coordinate system,
    ///   top-left origin.
    func viewPoint(forNormalized point: CGPoint) -> CGPoint
}
