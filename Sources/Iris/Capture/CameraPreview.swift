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
public struct CameraPreview: UIViewRepresentable {
    public let source: PreviewSource
    public let videoGravity: AVLayerVideoGravity

    public init(
        source: PreviewSource,
        videoGravity: AVLayerVideoGravity = .resizeAspect
    ) {
        self.source = source
        self.videoGravity = videoGravity
    }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        source.connect(to: view)
        view.previewLayer.videoGravity = videoGravity
        view.observePreviewAngles(source.previewAngles)
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
    public let previewAngles: AsyncStream<CGFloat>

    public init() {
        // Empty stream: never yields, never finishes. The consumer Task on
        // PreviewView just sits idle.
        self.previewAngles = AsyncStream { _ in }
    }

    @MainActor public func connect(to target: PreviewTarget) {
        // No-op.
    }
}

#Preview {
    CameraPreview(source: MockPreviewSource())
}

#endif
