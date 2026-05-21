#if os(iOS)

@preconcurrency import AVFoundation

/// Internal `PreviewSource` concrete that holds a reference to the live
/// `AVCaptureSession` and hands it to the SwiftUI preview view on
/// `@MainActor`.
///
/// `@unchecked Sendable` invariant: the `session` reference is captured once
/// at `init` and never mutated through this class. The `AVCaptureSession`
/// object itself has internal threading guarantees managed by AVFoundation;
/// this wrapper only ever reads the reference.
final class AVCapturePreviewSource: PreviewSource, @unchecked Sendable {

    private let session: AVCaptureSession

    init(session: AVCaptureSession) {
        self.session = session
    }

    @MainActor func connect(to target: PreviewTarget) {
        // Caller is already on MainActor (per the protocol contract); hand
        // the session directly. The CALayer assignment inside setSession
        // runs on the main thread, as required.
        target.setSession(session)
    }
}

#endif
