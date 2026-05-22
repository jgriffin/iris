#if os(iOS)

@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO
import os

/// AVF sample-buffer delegate. Bridges `captureOutput(_:didOutput:from:)`
/// into the `AsyncStream<Frame>` continuation owned by `CaptureSession`.
///
/// Invariant justifying `@unchecked Sendable`: every method on this class
/// only ever runs on the `CaptureSession` actor's executor — the delegate
/// queue passed to `setSampleBufferDelegate(_:queue:)` is the *same*
/// `DispatchSerialQueue` that backs the actor's `unownedExecutor`. The
/// class has no mutable stored state after `init`, so concurrent reads of
/// the stored references are safe.
final class SampleBufferRouter:
    NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{

    static let logger = Logger(subsystem: "iris.capture", category: "router")

    private let continuation: AsyncStream<Frame>.Continuation
    private let cameraID: CameraDevice.ID

    init(
        continuation: AsyncStream<Frame>.Continuation,
        cameraID: CameraDevice.ID
    ) {
        self.continuation = continuation
        self.cameraID = cameraID
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            Self.logger.warning("captureOutput: sample buffer had no image buffer")
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // The data-output connection's `videoRotationAngle` is what AVF
        // actually rotates the buffer by — set in
        // `CaptureSession.configureSession` from
        // `RotationCoordinator.videoRotationAngleForHorizonLevelCapture`,
        // and kept in sync via KVO. The frame is therefore already
        // horizon-level by the time it reaches us; tag with the EXIF-up
        // baseline rather than re-deriving an angle here.
        //
        // M3 Phase 1 cleanup: the previous design plumbed a per-frame
        // `rotation: @Sendable () async -> CGFloat` closure into this
        // router as a deferred optimization, but it was never read. Removed
        // — the connection-level rotation is the source of truth.
        let frame = Frame(
            pixelBuffer: pixelBuffer,
            timestamp: timestamp,
            orientation: .up,
            source: .camera(cameraID),
            format: .yuv420BiPlanarFull,
            dimensions: CGSize(width: width, height: height)
        )

        // Synchronous yield — no Task spawn, no actor hop. The continuation
        // is `.bufferingNewest(1)`, so back-pressure is automatic.
        continuation.yield(frame)
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Never yield to the stream on a drop. Just log.
        let reason = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
            attachmentModeOut: nil
        )
        Self.logger.notice("dropped frame: \(String(describing: reason), privacy: .public)")
    }
}

#endif
