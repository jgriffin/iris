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
    public let frames: AsyncStream<Frame>
    public private(set) var state: SourceState = .idle

    // MARK: - Private storage

    private let session: AVCaptureSession
    private var input: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private var router: SampleBufferRouter?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
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

        // Rotation: observe `videoRotationAngleForHorizonLevelCapture` (the
        // angle Vision wants) and apply it to the data-output connection.
        // We don't have a preview-layer reference here; the preview path's
        // own connection rotation is handled by AVF when the layer attaches
        // the session in `PreviewView.setSession`. Per-camera-side preview
        // rotation tuning is deferred — see runtime-pipeline-architecture
        // §"Open items deferred".
        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device,
            previewLayer: nil
        )
        self.rotationCoordinator = coordinator
        if let dataConnection = videoOutput.connection(with: .video) {
            dataConnection.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelCapture
            dataConnection.isVideoMirrored = false
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
