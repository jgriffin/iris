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
public struct CameraPreview: UIViewRepresentable {
    public let source: PreviewSource

    public init(source: PreviewSource) {
        self.source = source
    }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        source.connect(to: view)
        return view
    }

    public func updateUIView(_ uiView: PreviewView, context: Context) {
        // No-op: session attachment is one-shot at make time.
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        ObjectIdentifier(lhs.source as AnyObject) == ObjectIdentifier(rhs.source as AnyObject)
    }
}

/// A no-op `PreviewSource` for SwiftUI previews and tests. Connecting it to
/// a target does nothing, so the view renders as an empty black surface —
/// enough to validate layout without spinning up a camera.
public final class MockPreviewSource: PreviewSource, @unchecked Sendable {
    public init() {}
    public func connect(to target: PreviewTarget) {
        // No-op.
    }
}

#Preview {
    CameraPreview(source: MockPreviewSource())
}

#endif
