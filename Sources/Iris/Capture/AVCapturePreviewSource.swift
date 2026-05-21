#if os(iOS)

@preconcurrency import AVFoundation

/// Internal `PreviewSource` concrete that holds a reference to the live
/// `AVCaptureSession` and hands it to the SwiftUI preview view on
/// `@MainActor`. Also carries the preview-side rotation angle stream that
/// `CaptureSession` feeds from its `RotationCoordinator`.
///
/// `@unchecked Sendable` invariant: the `session` reference is captured once
/// at `init` and never mutated through this class. The `AVCaptureSession`
/// object itself has internal threading guarantees managed by AVFoundation;
/// this wrapper only ever reads the reference. The angle stream's
/// `Continuation` is itself thread-safe.
final class AVCapturePreviewSource: PreviewSource, @unchecked Sendable {

    private let session: AVCaptureSession
    let previewAngles: AsyncStream<CGFloat>
    private let angleContinuation: AsyncStream<CGFloat>.Continuation

    init(session: AVCaptureSession) {
        self.session = session
        let (stream, cont) = AsyncStream<CGFloat>.makeStream(
            of: CGFloat.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.previewAngles = stream
        self.angleContinuation = cont
    }

    @MainActor func connect(to target: PreviewTarget) {
        // Caller is already on MainActor (per the protocol contract); hand
        // the session directly. The CALayer assignment inside setSession
        // runs on the main thread, as required.
        target.setSession(session)
    }

    /// Push a new preview rotation angle into the stream. Called by
    /// `CaptureSession` when the `RotationCoordinator` observes a change
    /// to `videoRotationAngleForHorizonLevelPreview`. Safe from any thread —
    /// `AsyncStream.Continuation.yield` is documented thread-safe.
    func publishPreviewAngle(_ angle: CGFloat) {
        angleContinuation.yield(angle)
    }

    /// Tear down the angle stream. Called by `CaptureSession.invalidate()`.
    func finishAngleStream() {
        angleContinuation.finish()
    }
}

#endif
