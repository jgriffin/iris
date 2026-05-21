#if os(iOS)

import AVFoundation

/// A `Sendable` indirection that lets the SwiftUI preview view receive an
/// `AVCaptureSession` without the capture actor having to expose the session
/// directly. `CaptureSession` vends a concrete `PreviewSource` as a
/// `nonisolated let`; the preview view conforms to `PreviewTarget` and
/// receives the session on `@MainActor` via `connect(to:)`.
public protocol PreviewSource: Sendable {
    /// Hand the underlying `AVCaptureSession` to the `target`. Must be called
    /// on `@MainActor` — typical caller is `CameraPreview.makeUIView` which
    /// is already `@MainActor`-isolated by `UIViewRepresentable`.
    @MainActor func connect(to target: PreviewTarget)
}

/// The receiving side of the preview indirection. Implemented by the
/// internal `PreviewView` (a `UIView` whose `layerClass` is
/// `AVCaptureVideoPreviewLayer.self`). `setSession` runs on `@MainActor` so
/// the layer assignment is on the main thread, as `CALayer` requires.
///
/// The protocol itself is not `@MainActor`-pinned so the existential
/// `any PreviewTarget` can be stored and passed across isolation domains;
/// the only constraint is that `setSession` runs on MainActor.
public protocol PreviewTarget: AnyObject {
    @MainActor func setSession(_ session: AVCaptureSession)
}

#endif
