import Iris
import SwiftUI
import os

// MARK: - Capture detail (M9·P3)
//
// iOS-only live camera. macOS has no camera, so the detail is a placeholder
// there (and the sidebar Capture row is disabled). The camera lifecycle is
// driven by the shell off the active-page selection (see `onPageChanged`),
// NOT view `.onDisappear` — preserving the documented AVFoundation safety.
extension IrisShell {

    @ViewBuilder
    var captureDetail: some View {
        #if os(iOS)
        CaptureDetailContent(
            capture: capture,
            minConfidence: Float(modelSelection.minConfidence),
            onInspect: { inspectFrame($0) }
        )
        #else
        ContentUnavailableView {
            Label("Capture isn't available on macOS", systemImage: "camera.fill")
        } description: {
            Text("Use Playback or Image. Live camera capture runs on iOS / iPadOS.")
        }
        #endif
    }
}

#if os(iOS)
import AVFoundation

/// The live-capture detail content (M9·P3·3 extraction of the prior
/// `CaptureContentView`'s preview + overlay + Inspect button). The camera
/// session itself is owned by `CaptureModel`, started/torn-down by the shell.
struct CaptureDetailContent: View {
    let capture: CaptureModel
    let minConfidence: Float
    let onInspect: (Frame?) -> Void

    var body: some View {
        ZStack {
            if !CaptureModel.cameraAvailable {
                cameraUnavailableView
            } else if let session = capture.session, let converter = capture.converter {
                CameraPreview(
                    source: session.previewSource,
                    videoGravity: .resizeAspectFill,
                    onPreviewLayerReady: { _ in }
                )
                .ignoresSafeArea()

                DetectionLayer(
                    store: capture.resultStore,
                    makeConverter: { _ in converter },
                    minConfidence: minConfidence
                )
                .ignoresSafeArea()
            } else if let session = capture.session {
                // Session up, converter not yet ready: show preview to bind it.
                CameraPreview(
                    source: session.previewSource,
                    videoGravity: .resizeAspectFill,
                    onPreviewLayerReady: { layer in capture.bindConverter(layer) }
                )
                .ignoresSafeArea()
            } else if let errorText = capture.errorText {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(errorText).multilineTextAlignment(.center).padding()
                }
            } else {
                ProgressView("Starting capture…")
            }
        }
        .overlay(alignment: .topTrailing) {
            if CaptureModel.cameraAvailable, capture.lastFrame != nil {
                Button {
                    onInspect(capture.lastFrame)
                } label: {
                    Image(systemName: "camera.viewfinder")
                        .font(.title3)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Inspect frame")
                .padding(16)
            }
        }
        // Bind the converter once the preview layer is ready (when the layer
        // becomes available after the session starts).
        .task(id: capture.sessionToken) {
            // No-op driver: keeps the view re-evaluating as the session token
            // bumps so the converter binding path above re-runs.
        }
    }

    @ViewBuilder
    private var cameraUnavailableView: some View {
        ContentUnavailableView {
            Label("Camera isn't available here", systemImage: "camera.fill")
        } description: {
            Text(
                """
                The Simulator and Mac (Designed for iPad) have no camera. \
                Run on a physical iPhone to use Capture. Use Playback to work \
                with video files.
                """
            )
        }
    }
}

/// Owns the live `CaptureSession` + its `ResultStore` and the per-frame detect
/// loop. The shell drives `start` / `teardown` off the active-page selection so
/// the camera is only live while the Capture page is shown — preserving the
/// AVFoundation safety the prior `CaptureContentView` documented
/// (`videoDeviceNotAvailableInBackground` + double-session race). M9·P4 will
/// add the live detector swap; for now Capture runs the shared detector
/// installed at start (Vision rectangles by default).
@MainActor
@Observable
final class CaptureModel {
    private(set) var session: CaptureSession?
    private(set) var converter: PreviewLayerConverter?
    private(set) var lastFrame: Frame?
    private(set) var errorText: String?

    let resultStore = ResultStore()
    let metrics = DetectionMetrics()

    /// Bumped on each start so the view's `.task(id:)` re-runs.
    private(set) var sessionToken = 0

    /// The detector to run. Defaults to Vision rectangles (the prior hardcoded
    /// behavior); `updateDetector` swaps it when the shared selection changes.
    private var detector: any Detector = CaptureModel.defaultDetector

    private var loopTask: Task<Void, Never>?

    static let defaultDetector: any Detector = VisionRectanglesDetector(
        minimumAspectRatio: 0.3,
        maximumAspectRatio: 1.0,
        minimumSize: 0.1,
        label: "rect"
    )

    static var cameraAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    private static let logger = Logger(subsystem: "iris.demo", category: "capture")

    init() {}

    /// Bind the preview-layer converter once the layer is ready.
    func bindConverter(_ layer: AVCaptureVideoPreviewLayer) {
        converter = PreviewLayerConverter(previewLayer: layer)
    }

    /// Start the session + detect loop. No-op if already running or no camera.
    func start(minConfidence: @escaping () -> Float) {
        guard Self.cameraAvailable, session == nil else { return }
        let new = CaptureSession()
        sessionToken += 1
        Task { @MainActor in
            do {
                try await new.start()
            } catch {
                errorText = "Capture start failed: \(error)"
                Self.logger.error("\(self.errorText ?? "", privacy: .public)")
                return
            }
            session = new
            errorText = nil
            loopTask = Task { @MainActor in
                for await frame in new.frames {
                    lastFrame = frame
                    do {
                        let detections = try await detector.detect(in: frame)
                        resultStore.append(
                            TimestampedDetections(timestamp: frame.timestamp, detections: detections)
                        )
                    } catch {
                        Self.logger.error("detect failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }
    }

    /// Swap the live detector (M9·P4 will wire the shared selection through a
    /// catalog entry; for now this keeps the default unless given one).
    func updateDetector(for entry: DetectorCatalogEntry?) {
        // Capture stays on its default detector until M9·P4. Hook kept so the
        // shell's detector-change handler has a uniform call site.
    }

    /// Stop AVF + the detect loop, clear the result store. Idempotent.
    func teardown() {
        loopTask?.cancel()
        loopTask = nil
        let priorSession = session
        session = nil
        converter = nil
        lastFrame = nil
        resultStore.clear()
        errorText = nil
        if let priorSession {
            Task { await priorSession.invalidate() }
        }
    }
}
#endif
