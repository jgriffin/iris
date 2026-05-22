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
/// **Preview rotation** is owned here. When `setSession(_:)` is called, the
/// view spins up its own `AVCaptureDevice.RotationCoordinator` bound to
/// `self.previewLayer` and the session's input device, then observes
/// `videoRotationAngleForHorizonLevelPreview` to keep the preview
/// horizon-level. Initializing the coordinator with the actual preview layer
/// (rather than `previewLayer: nil`) is required for the angle to
/// compensate for the layer's interface orientation; with `nil` the property
/// returns 0 in portrait, leaving the preview rotated 90° counterclockwise.
/// This matches Apple's AVCam sample.
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

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    public func setSession(_ session: AVCaptureSession) {
        previewLayer.session = session
        installRotationCoordinator(session: session)
        // videoGravity is set by `CameraPreview` after `connect(to:)` so it
        // can be configured by consumers.
    }

    /// Bind a `RotationCoordinator` to `self.previewLayer` and the session's
    /// input device, apply the initial preview-side angle, and observe
    /// changes. Replaces any prior coordinator.
    @MainActor private func installRotationCoordinator(session: AVCaptureSession) {
        rotationObservation?.invalidate()
        rotationObservation = nil

        guard
            let input = session.inputs.first as? AVCaptureDeviceInput
        else {
            return
        }

        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: input.device,
            previewLayer: previewLayer
        )
        self.rotationCoordinator = coordinator

        let initialAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        previewLayer.connection?.videoRotationAngle = initialAngle

        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.new]
        ) { [weak self] _, change in
            guard let newAngle = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.previewLayer.connection?.videoRotationAngle = newAngle
            }
        }
    }

    deinit {
        rotationObservation?.invalidate()
    }
}

#endif
