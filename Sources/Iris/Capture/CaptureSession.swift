#if os(iOS)

@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os

/// Live camera capture as a `Source`.
///
/// `CaptureSession` is an `actor` *instance* whose custom serial executor is
/// a `DispatchSerialQueue` shared with the `AVCaptureVideoDataOutput`
/// delegate queue. Frames therefore arrive *already isolated to the actor*
/// — no `Task { … }` per frame, no actor hop.
///
/// Mirroring split (display-pipeline-architecture decision 17): the preview
/// connection's `isVideoMirrored` follows camera position so the user sees a
/// mirrored selfie image; the data-output connection stays unmirrored so
/// Vision sees the raw orientation.
///
/// Public preview surface is `previewSource` (a `nonisolated let
/// PreviewSource`) — the SwiftUI `CameraPreview` view consumes it via
/// `connect(to:)` without ever touching the underlying `AVCaptureSession`.
///
/// **Rotation responsibility split.** This actor owns the *capture*-side
/// `RotationCoordinator` only — its `videoRotationAngleForHorizonLevelCapture`
/// is applied to the data-output connection so Vision sees horizon-level
/// pixels. *Preview*-side rotation lives in `PreviewView` (the MainActor
/// site that holds the `AVCaptureVideoPreviewLayer`), because
/// `videoRotationAngleForHorizonLevelPreview` only compensates correctly
/// when the coordinator is initialized with the real preview layer.
public actor CaptureSession: Source {

    // MARK: - Executor

    private let captureQueue = DispatchSerialQueue(label: "iris.capture.session")

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        captureQueue.asUnownedSerialExecutor()
    }

    // MARK: - Public surface

    public nonisolated let previewSource: PreviewSource
    public nonisolated let frames: AsyncStream<Frame>
    public private(set) var state: SourceState = .idle

    // MARK: - Private storage

    private let session: AVCaptureSession
    private var input: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private var router: SampleBufferRouter?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var captureRotationObservation: NSKeyValueObservation?
    private let continuation: AsyncStream<Frame>.Continuation
    private let logger = Logger(subsystem: "iris.capture", category: "session")

    /// Notification observer tokens for interruption / runtime-error
    /// recovery. Registered in `configureSession(for:)`, removed in
    /// `invalidate()`. Holding `NSObjectProtocol` tokens (rather than
    /// `addObserver(_:selector:…)`) keeps the observer closure-based and
    /// lets us cleanly remove without an `@objc` shim.
    private var interruptionObservers: [NSObjectProtocol] = []

    // MARK: - Init

    public init() {
        let (stream, cont) = AsyncStream<Frame>.makeStream(
            of: Frame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let session = AVCaptureSession()
        self.session = session
        self.frames = stream
        self.continuation = cont
        self.previewSource = AVCapturePreviewSource(session: session)
    }

    // MARK: - Source

    public func start() async throws {
        if state == .running { return }
        state = .requestingPermission

        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else {
            state = .permissionDenied(.video)
            throw SourceError.permissionDenied(.video)
        }

        guard
            let device = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            )
        else {
            state = .failed(.noDeviceAvailable)
            throw SourceError.noDeviceAvailable
        }

        do {
            try configureSession(for: device)
        } catch let error as SourceError {
            state = .failed(error)
            throw error
        } catch {
            let wrapped = SourceError.configurationFailed(String(describing: error))
            state = .failed(wrapped)
            throw wrapped
        }

        // `startRunning()` is synchronous and blocking — runs on our serial
        // executor's queue (a background queue), which is what AVF requires.
        session.startRunning()
        state = .running
    }

    public func stop() async {
        if session.isRunning {
            session.stopRunning()
        }
        state = .stopped
    }

    public func invalidate() async {
        captureRotationObservation?.invalidate()
        captureRotationObservation = nil
        for token in interruptionObservers {
            NotificationCenter.default.removeObserver(token)
        }
        interruptionObservers.removeAll()
        continuation.finish()
        if session.isRunning {
            session.stopRunning()
        }
    }

    // MARK: - Device discovery

    /// Enumerate built-in cameras on the host.
    public static func discoverDevices() async -> [CameraDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera,
                .builtInTrueDepthCamera,
            ],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map { device in
            CameraDevice(
                id: device.uniqueID,
                position: Self.mapPosition(device.position),
                kind: Self.mapKind(device.deviceType)
            )
        }
    }

    // MARK: - Configuration (actor-isolated)

    private func configureSession(for device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let deviceInput: AVCaptureDeviceInput
        do {
            deviceInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw SourceError.configurationFailed("AVCaptureDeviceInput init failed: \(error)")
        }
        guard session.canAddInput(deviceInput) else {
            throw SourceError.configurationFailed("session.canAddInput == false")
        }
        session.addInput(deviceInput)
        self.input = deviceInput

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        let cameraID = device.uniqueID
        let router = SampleBufferRouter(
            continuation: continuation,
            cameraID: cameraID
        )
        videoOutput.setSampleBufferDelegate(router, queue: captureQueue)
        self.router = router

        guard session.canAddOutput(videoOutput) else {
            throw SourceError.configurationFailed("session.canAddOutput == false")
        }
        session.addOutput(videoOutput)

        // Capture-side rotation: this coordinator's
        // `videoRotationAngleForHorizonLevelCapture` is independent of any
        // preview layer, so `previewLayer: nil` is correct here. The
        // *preview*-side coordinator lives in `PreviewView` (see its
        // doc-comment) because the preview-angle property only returns the
        // layer-orientation-compensated value when initialized with the
        // actual preview layer.
        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device,
            previewLayer: nil
        )
        self.rotationCoordinator = coordinator

        if let dataConnection = videoOutput.connection(with: .video) {
            dataConnection.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelCapture
            dataConnection.isVideoMirrored = false
        }

        // KVO callbacks arrive on an arbitrary queue — hop back to the
        // actor's executor before mutating the data-output connection.
        captureRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.new]
        ) { [weak self] _, change in
            guard let newAngle = change.newValue else { return }
            Task { [weak self] in
                await self?.applyCaptureAngle(newAngle)
            }
        }

        installInterruptionObservers()
    }

    // MARK: - Interruption recovery (M3 Phase 6, M2-deferred carryover)

    /// Wire `AVCaptureSession`'s interruption / runtime-error notifications
    /// onto the actor's executor.
    ///
    /// **Doctrine.** Per the M3.md §M2-deferred items folded in, the iOS app
    /// is where interruptions actually happen (incoming calls, control-center
    /// pulldown, route conflicts). We follow the preferred recovery shape
    /// from the brief: on interruption, *keep `state == .running` and log*
    /// — AVF resumes automatically when `interruptionEndedNotification`
    /// fires for the common reasons (incoming call, control-center).
    /// Strict-failure-on-interrupt would force callers to handle a state
    /// transition that the system is about to undo on its own, which is
    /// the wrong UX default.
    ///
    /// On `interruptionEndedNotification`, defensively call `startRunning()`
    /// if the session isn't already running — covers the rare reasons
    /// (`videoDeviceNotAvailableInBackground`, route conflicts) where AVF
    /// doesn't auto-resume. `startRunning()` is a no-op when already
    /// running, so this is safe in the common case.
    ///
    /// On `runtimeErrorNotification`, transition to
    /// `.failed(.captureRuntimeError(...))` — a runtime error means AVF
    /// has given up on the session and the caller needs to know.
    ///
    /// **Threading.** Notification posts can arrive on any queue. The
    /// observer closures bounce onto a `Task` that's actor-isolated, so
    /// the actual handler runs on the capture queue. The observer tokens
    /// themselves are removed in `invalidate()`.
    private func installInterruptionObservers() {
        let center = NotificationCenter.default

        // `object: session` scopes the observer to *this* session — other
        // `AVCaptureSession` instances in the same process (rare, but
        // possible in tests) won't trigger us.
        let interruptedToken = center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let userInfo = notification.userInfo
            let rawReason = (userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? -1
            Task { [weak self] in
                await self?.handleInterruption(reasonRawValue: rawReason)
            }
        }

        let endedToken = center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handleInterruptionEnded()
            }
        }

        let runtimeErrorToken = center.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let nsError = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let description = nsError?.localizedDescription ?? "unknown runtime error"
            Task { [weak self] in
                await self?.handleRuntimeError(description: description)
            }
        }

        interruptionObservers = [interruptedToken, endedToken, runtimeErrorToken]
    }

    /// Handle `wasInterruptedNotification`. Logs the reason; does NOT
    /// transition state (the system will resume automatically on
    /// `interruptionEndedNotification` for the common reasons).
    private func handleInterruption(reasonRawValue: Int) {
        let reason = AVCaptureSession.InterruptionReason(rawValue: reasonRawValue)
        let reasonName = reason.map(Self.interruptionReasonName) ?? "unknown(\(reasonRawValue))"
        logger.notice(
            "capture interrupted: reason=\(reasonName, privacy: .public); state preserved as .running, awaiting resume"
        )
    }

    /// Handle `interruptionEndedNotification`. Defensively restart the
    /// session if AVF hasn't auto-resumed (rare — most reasons resume on
    /// their own).
    private func handleInterruptionEnded() {
        if !session.isRunning {
            logger.notice("interruption ended; session not auto-resumed, calling startRunning()")
            session.startRunning()
        } else {
            logger.notice("interruption ended; session auto-resumed")
        }
    }

    /// Handle `runtimeErrorNotification`. Transition to `.failed(...)` —
    /// runtime errors are unrecoverable from inside the session.
    private func handleRuntimeError(description: String) {
        logger.error("capture runtime error: \(description, privacy: .public)")
        state = .failed(.captureRuntimeError(description))
    }

    /// Stable human-readable name for `AVCaptureSession.InterruptionReason`,
    /// used in log lines so they're greppable across iOS versions where
    /// the raw value semantics could shift.
    private static func interruptionReasonName(
        _ reason: AVCaptureSession.InterruptionReason
    ) -> String {
        switch reason {
        case .videoDeviceNotAvailableInBackground:
            return "videoDeviceNotAvailableInBackground"
        case .audioDeviceInUseByAnotherClient:
            return "audioDeviceInUseByAnotherClient"
        case .videoDeviceInUseByAnotherClient:
            return "videoDeviceInUseByAnotherClient"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "videoDeviceNotAvailableWithMultipleForegroundApps"
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "videoDeviceNotAvailableDueToSystemPressure"
        case .sensitiveContentMitigationActivated:
            return "sensitiveContentMitigationActivated"
        @unknown default:
            return "unknown(\(reason.rawValue))"
        }
    }

    // MARK: - Helpers

    /// Apply a new capture-side rotation angle to the data-output connection.
    /// Called from a `Task` spawned by the `RotationCoordinator` KVO observer,
    /// so the connection mutation happens on the actor's serial executor.
    private func applyCaptureAngle(_ angle: CGFloat) {
        videoOutput.connection(with: .video)?.videoRotationAngle = angle
    }

    private static func mapPosition(_ position: AVCaptureDevice.Position) -> CameraDevice.Position {
        switch position {
        case .front: return .front
        case .back: return .back
        case .unspecified: return .external
        @unknown default: return .external
        }
    }

    private static func mapKind(_ kind: AVCaptureDevice.DeviceType) -> CameraDevice.Kind {
        switch kind {
        case .builtInWideAngleCamera: return .wide
        case .builtInUltraWideCamera: return .ultraWide
        case .builtInTelephotoCamera: return .telephoto
        case .builtInTrueDepthCamera: return .trueDepth
        default: return .external
        }
    }
}

#endif
