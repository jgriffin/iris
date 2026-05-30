import Iris
import SwiftUI
import os

// MARK: - Capture detail routing (M9·P3)
//
// iOS-only live camera. macOS has no camera, so the detail is a placeholder
// there (and the sidebar Capture row is disabled). The camera lifecycle is
// driven by the shell off the active-page selection (see `onPageChanged`),
// NOT view `.onDisappear` — preserving the documented AVFoundation safety.
extension IrisShell {

    @ViewBuilder
    var captureDetail: some View {
        #if os(iOS)
        CaptureDetailView(
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

/// Owns the live `CaptureSession` + its `ResultStore` and the per-frame detect
/// loop. The shell drives `start` / `teardown` off the active-page selection so
/// the camera is only live while the Capture page is shown — preserving the
/// AVFoundation safety the prior `CaptureContentView` documented
/// (`videoDeviceNotAvailableInBackground` + double-session race). M9·P4 will
/// add the live detector swap; for now Capture runs Vision rectangles.
@MainActor
@Observable
final class CaptureModel {
    private(set) var session: CaptureSession?
    private(set) var converter: PreviewLayerConverter?
    private(set) var lastFrame: Frame?
    private(set) var errorText: String?

    let resultStore = ResultStore()
    let metrics = DetectionMetrics()

    /// The detector to run. Defaults to Vision rectangles (the prior hardcoded
    /// behavior); `updateDetector` is the M9·P4 hook for the shared selection.
    private let detector: any Detector = CaptureModel.defaultDetector

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
            loopTask = Task { @MainActor [detector] in
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

    /// M9·P4 hook: swap the live detector when the shared selection changes.
    /// Capture stays on its default detector until then; this keeps the shell's
    /// detector-change handler with a uniform call site.
    func updateDetector(for entry: DetectorCatalogEntry?) {}

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
