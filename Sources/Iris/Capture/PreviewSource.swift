#if os(iOS)

import AVFoundation

/// A `Sendable` indirection that lets the SwiftUI preview view receive an
/// `AVCaptureSession` without the capture actor having to expose the session
/// directly. `CaptureSession` vends a concrete `PreviewSource` as a
/// `nonisolated let`; the preview view conforms to `PreviewTarget` and
/// receives the session on `@MainActor` via `connect(to:)`.
public protocol PreviewSource: Sendable {
    /// Hand the underlying `AVCaptureSession` to the `target`. The
    /// implementation must dispatch the call to `@MainActor` because
    /// `PreviewTarget.setSession` is `@MainActor`-isolated.
    func connect(to target: PreviewTarget)
}

/// The receiving side of the preview indirection. Implemented by the
/// internal `PreviewView` (a `UIView` whose `layerClass` is
/// `AVCaptureVideoPreviewLayer.self`). `@MainActor` so the layer assignment
/// runs on the main thread, as `CALayer` requires.
@MainActor public protocol PreviewTarget {
    func setSession(_ session: AVCaptureSession)
}

#endif
