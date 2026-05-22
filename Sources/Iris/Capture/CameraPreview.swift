#if os(iOS)

@preconcurrency import AVFoundation
import SwiftUI

/// SwiftUI surface for the live camera preview.
///
/// Wraps an internal `PreviewView` (a `UIView` whose backing layer is the
/// `AVCaptureVideoPreviewLayer`) behind a `UIViewRepresentable`. SwiftUI
/// never sees the `UIView` or the layer.
///
/// `==` is overridden to use `ObjectIdentifier` on the `PreviewSource` so
/// SwiftUI doesn't tear down and rebuild the underlying `UIView` on every
/// state-change in the parent — the source identity is stable for the
/// session's lifetime, so equality on identity is safe.
///
/// `videoGravity` defaults to `.resizeAspect` (display-pipeline-architecture
/// decision 4: aspect-fit with letterbox produces the predictable geometry
/// the overlay coordinate math is built against). Apps that want fullscreen
/// camera ergonomics pass `.resizeAspectFill` instead.
///
/// **`onPreviewLayerReady`** fires once on MainActor inside `makeUIView` and
/// hands the consumer the `AVCaptureVideoPreviewLayer` backing the view —
/// the seam needed to construct a `PreviewLayerConverter` for `DetectionLayer`.
/// Default is a no-op so M1 callers stay untouched. The closure is invoked
/// exactly once per `makeUIView`; SwiftUI may recreate the underlying view
/// (e.g. across structural identity changes), in which case the closure
/// fires again with the new layer.
public struct CameraPreview: UIViewRepresentable {
    public let source: PreviewSource
    public let videoGravity: AVLayerVideoGravity
    private let onPreviewLayerReady: @MainActor (AVCaptureVideoPreviewLayer) -> Void

    public init(
        source: PreviewSource,
        videoGravity: AVLayerVideoGravity = .resizeAspect,
        onPreviewLayerReady: @escaping @MainActor (AVCaptureVideoPreviewLayer) -> Void = { _ in }
    ) {
        self.source = source
        self.videoGravity = videoGravity
        self.onPreviewLayerReady = onPreviewLayerReady
    }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        source.connect(to: view)
        view.previewLayer.videoGravity = videoGravity
        onPreviewLayerReady(view.previewLayer)
        return view
    }

    public func updateUIView(_ uiView: PreviewView, context: Context) {
        // Only thing that can change post-make is videoGravity. Session
        // attachment is one-shot; angle subscription is owned by makeUIView.
        if uiView.previewLayer.videoGravity != videoGravity {
            uiView.previewLayer.videoGravity = videoGravity
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        ObjectIdentifier(lhs.source as AnyObject) == ObjectIdentifier(rhs.source as AnyObject)
            && lhs.videoGravity == rhs.videoGravity
    }
}

/// A no-op `PreviewSource` for SwiftUI previews and tests. Connecting it to
/// a target does nothing, so the view renders as an empty black surface —
/// enough to validate layout without spinning up a camera.
public final class MockPreviewSource: PreviewSource, @unchecked Sendable {
    public init() {}

    @MainActor public func connect(to target: PreviewTarget) {
        // No-op.
    }
}

#Preview {
    CameraPreview(source: MockPreviewSource())
}

#endif
