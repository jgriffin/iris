#if os(iOS)

@preconcurrency import AVFoundation
import CoreGraphics

/// `NormalizedGeometryConverting` backend for the live-capture display
/// path. Delegates to `AVCaptureVideoPreviewLayer.layerRectConverted(...)`
/// / `layerPointConverted(...)`, which handle the `videoGravity` letterbox
/// math and front-camera mirroring internally (per the locked decision in
/// `explorations/display-pipeline-architecture/RECOMMENDATIONS.md` §26).
///
/// **No external box geometry.** AVF's `layerRectConverted(fromMetadataOutputRect:)`
/// returns the on-screen rect in the *layer's* coordinate space, accounting
/// for letterbox internally — for capture, the layer's own bounds and
/// `videoGravity` are authoritative, so the converter takes no
/// caller-supplied size or rect.
///
/// **Main-actor requirement.** `AVCaptureVideoPreviewLayer` is a `CALayer`,
/// which is `@MainActor`-isolated; calling `layerRectConverted` on a
/// non-main thread is undefined. The protocol methods are nonisolated by
/// `NormalizedGeometryConverting`'s contract, so this conformer uses
/// `MainActor.assumeIsolated` to read the layer. Callers must invoke from
/// `@MainActor` — in practice, `DetectionLayer`'s `Canvas` body runs on
/// MainActor (SwiftUI `Canvas` rendering is main-actor-isolated), so this
/// is satisfied by construction.
///
/// **`@unchecked Sendable` invariant.** The `AVCaptureVideoPreviewLayer`
/// reference is captured once at `init` and never mutated through this
/// struct. The conversion methods only *read* the layer, and only from
/// MainActor (enforced by `MainActor.assumeIsolated`). CALayer's internal
/// threading is AVF-managed; this wrapper holds the reference and reads it
/// behind the MainActor seam.
public struct PreviewLayerConverter: NormalizedGeometryConverting, @unchecked Sendable {

    private let previewLayer: AVCaptureVideoPreviewLayer

    public init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
    }

    public func viewRect(forNormalized rect: CGRect) -> CGRect {
        MainActor.assumeIsolated {
            previewLayer.layerRectConverted(fromMetadataOutputRect: rect)
        }
    }

    public func viewPoint(forNormalized point: CGPoint) -> CGPoint {
        MainActor.assumeIsolated {
            previewLayer.layerPointConverted(fromCaptureDevicePoint: point)
        }
    }
}

#endif
