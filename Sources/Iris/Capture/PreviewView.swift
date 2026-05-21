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

    private var rotationTask: Task<Void, Never>?

    public func setSession(_ session: AVCaptureSession) {
        previewLayer.session = session
        // videoGravity is set by `CameraPreview` after `connect(to:)` so it
        // can be configured by consumers.
    }

    /// Subscribe to a stream of preview rotation angles (in degrees) and
    /// apply each to the preview layer's connection on MainActor. Replaces
    /// any prior subscription.
    @MainActor func observePreviewAngles(_ stream: AsyncStream<CGFloat>) {
        rotationTask?.cancel()
        rotationTask = Task { @MainActor [weak self] in
            for await angle in stream {
                self?.previewLayer.connection?.videoRotationAngle = angle
            }
        }
    }

    deinit {
        rotationTask?.cancel()
    }
}

#endif
