#if os(iOS)

@preconcurrency import AVFoundation
import UIKit

/// `UIView` whose backing layer *is* the `AVCaptureVideoPreviewLayer` — the
/// canonical AVF-native, hardware-accelerated preview surface. The
/// `layerClass` override avoids the sublayer-geometry plumbing that
/// `addSublayer(_:)` would require.
///
/// Conforms to `PreviewTarget` so `AVCapturePreviewSource` can hand it the
/// session on `@MainActor`.
///
/// Public only because it's the `UIViewType` exposed by `CameraPreview`
/// (Swift requires the type to be at least as visible as the public
/// `makeUIView` return). It is not part of the intended consumer surface
/// — apps should always use `CameraPreview`.
public final class PreviewView: UIView, PreviewTarget {

    public override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    public var previewLayer: AVCaptureVideoPreviewLayer {
        // Safe: layerClass override guarantees the layer is this type.
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }

    public func setSession(_ session: AVCaptureSession) {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
    }
}

#endif
