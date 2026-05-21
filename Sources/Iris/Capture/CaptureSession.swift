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
public actor CaptureSession: @preconcurrency Source {

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
    private var previewRotationObservation: NSKeyValueObservation?
    private let continuation: AsyncStream<Frame>.Continuation
    private let logger = Logger(subsystem: "iris.capture", category: "session")

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
        previewRotationObservation?.invalidate()
        previewRotationObservation = nil
        if let avSource = previewSource as? AVCapturePreviewSource {
            avSource.finishAngleStream()
        }
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
            cameraID: cameraID,
            rotation: { [weak self] in
                await self?.currentRotation() ?? 0
            }
        )
        videoOutput.setSampleBufferDelegate(router, queue: captureQueue)
        self.router = router

        guard session.canAddOutput(videoOutput) else {
            throw SourceError.configurationFailed("session.canAddOutput == false")
        }
        session.addOutput(videoOutput)

        // Rotation: own one `RotationCoordinator` and route its two angles
        // independently per display-pipeline-architecture decision 18 —
        //   videoRotationAngleForHorizonLevelCapture  → data-output connection
        //   videoRotationAngleForHorizonLevelPreview  → preview-layer connection
        //                                              (via PreviewSource.previewAngles)
        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device,
            previewLayer: nil
        )
        self.rotationCoordinator = coordinator

        // Apply initial angles.
        if let dataConnection = videoOutput.connection(with: .video) {
            dataConnection.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelCapture
            dataConnection.isVideoMirrored = false
        }
        if let avSource = previewSource as? AVCapturePreviewSource {
            avSource.publishPreviewAngle(coordinator.videoRotationAngleForHorizonLevelPreview)
        }

        // Observe ongoing changes. KVO callbacks arrive on an arbitrary
        // queue — for the capture side, hop back to the actor's executor
        // before mutating the connection; for the preview side, just yield
        // into the AsyncStream (the continuation is thread-safe).
        captureRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.new]
        ) { [weak self] _, change in
            guard let newAngle = change.newValue else { return }
            Task { [weak self] in
                await self?.applyCaptureAngle(newAngle)
            }
        }
        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.new]
        ) { [weak self] _, change in
            guard let newAngle = change.newValue else { return }
            guard let avSource = self?.previewSource as? AVCapturePreviewSource else { return }
            avSource.publishPreviewAngle(newAngle)
        }

        // TODO M1+: interruption recovery wiring. The AVF notifications
        // (`AVCaptureSession.wasInterruptedNotification` /
        // `interruptionEndedNotification`) need to bubble onto the actor's
        // executor — straightforward but adds a notification observer
        // bridge and an `actor`-isolated handler. Preview restart on
        // foreground works without it for the M1 smoke test.
    }

    // MARK: - Helpers

    private func currentRotation() -> CGFloat {
        rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 0
    }

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
