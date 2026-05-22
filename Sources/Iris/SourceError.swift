import Foundation

/// Session-level failures surfaced via `Source.state` (and thrown from
/// `Source.start()` where the caller can act on them — e.g. prompt-and-retry
/// on permission denial).
public enum SourceError: Error, Sendable, Equatable {
    case permissionDenied(MediaType)
    case noDeviceAvailable
    case assetLoadFailed(URL)
    case configurationFailed(String)
    case interrupted
    /// Capture session was interrupted by the system (incoming call,
    /// control-center pulldown, route conflict, background suspension).
    /// The raw value is `AVCaptureSession.InterruptionReason.rawValue`.
    /// Surfaced for diagnostics; the recovery contract is that
    /// `CaptureSession` keeps `state == .running` across most interruptions
    /// (AVF resumes automatically when `interruptionEndedNotification`
    /// fires) and only transitions to `.failed(.captureInterrupted)` if
    /// the caller explicitly opts into the strict-failure mode (not the
    /// default — see `CaptureSession`'s interruption handling).
    case captureInterrupted(reasonRawValue: Int)
    /// Capture session emitted a runtime error
    /// (`AVCaptureSession.runtimeErrorNotification`). The string holds the
    /// `NSError`'s localized description for logging / display; the
    /// underlying error is not retained because `NSError` isn't `Sendable`.
    case captureRuntimeError(String)
}
