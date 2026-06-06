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
            filter: overlayFilter,
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
/// (`videoDeviceNotAvailableInBackground` + double-session race).
///
/// **Shared model (M9·P4).** Capture runs the SAME `ModelSelection.detectorID`
/// as Playback and Image. `start(initialEntry:)` resolves the shared selection
/// into the detector the session opens with (default Vision rectangles if the
/// id is unresolvable / a model isn't ready), and `updateDetector(for:)` swaps
/// the live detector **in place** — the next frame runs through the new one,
/// with NO camera/session restart.
///
/// **Concurrency.** The model is `@MainActor`, so `detector` (read by the loop)
/// and `updateDetector` (the writer) are both main-actor-isolated — the swap is
/// data-race-free by construction. The loop reads `self.detector` fresh each
/// iteration (it does NOT capture a snapshot), so a mid-stream swap takes effect
/// on the next frame. Resolving an entry builds an `ActiveDetectorSession` only
/// to read its `router.currentDetector`; that has no side effect on the cache
/// (only the loop's explicit `append` writes), so it's safe to resolve against
/// `resultStore`.
@MainActor
@Observable
final class CaptureModel {
    private(set) var session: CaptureSession?
    private(set) var converter: PreviewLayerConverter?
    private(set) var lastFrame: Frame?
    private(set) var errorText: String?

    let resultStore = ResultStore()
    let metrics = DetectionMetrics()

    /// The detector the loop currently applies. `@MainActor`-isolated (the model
    /// is), so the loop's per-frame read and `updateDetector`'s write are on the
    /// same actor — no data race, no snapshot capture. Starts on the shared
    /// selection (set by `start(initialEntry:)`); defaults to Vision rectangles.
    private var detector: any Detector = CaptureModel.defaultDetector

    /// The catalog id of the detector currently installed in `detector` — the id
    /// to **attribute sightings to** (M12·P2). Set in lockstep with `detector`
    /// (`start` / `updateDetector`), both on `@MainActor`, so a frame's results
    /// and this id can't disagree: the loop reads `detector` + `installedDetectorID`
    /// in the same synchronous step, attributing each frame's labels to the exact
    /// detector that produced them across an in-place live swap. `nil` until the
    /// shared selection resolves (then the default detector has no catalog id).
    private(set) var installedDetectorID: String?

    /// Records the given labels as sightings for a detector id (M12·P2). Injected
    /// by the shell in `start` so `CaptureModel` stays decoupled from
    /// `DetectorLabelStore`; mirrors the `minConfidence` closure pattern.
    private var recordSightings: ((Set<String>, String) -> Void)?

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
    /// The session opens running `initialEntry`'s detector (the shared
    /// selection, resolved by the shell) so a model swapped while NOT on the
    /// Capture page is reflected when capture next starts; falls back to the
    /// default Vision detector if the entry is unresolvable / not ready.
    func start(
        initialEntry: DetectorCatalogEntry?,
        minConfidence: @escaping () -> Float,
        recordSightings: @escaping (Set<String>, String) -> Void
    ) {
        guard Self.cameraAvailable, session == nil else { return }
        detector = Self.resolveDetector(for: initialEntry)
        installedDetectorID = initialEntry?.id
        self.recordSightings = recordSightings
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
            loopTask = Task { @MainActor in
                for await frame in new.frames {
                    lastFrame = frame
                    // Read the CURRENT detector + its id each iteration so a live
                    // swap (updateDetector) takes effect on the next frame — no
                    // snapshot capture, no session restart. Reading both in one
                    // synchronous step ties each frame's results to the exact
                    // detector that produced them (M12·P2 attribution).
                    let active = detector
                    let attributedID = installedDetectorID
                    do {
                        let detections = try await active.detect(in: frame)
                        resultStore.append(
                            TimestampedDetections(timestamp: frame.timestamp, detections: detections)
                        )
                        // M12·P2: record sightings for the detector that ran this
                        // frame. `recordSightings` is idempotent + write-on-change,
                        // so the hot loop only touches the store on a new label.
                        if let attributedID, let recordSightings = self.recordSightings {
                            let labels = Set(detections.map(\.label).filter { !$0.isEmpty })
                            if !labels.isEmpty { recordSightings(labels, attributedID) }
                        }
                    } catch {
                        Self.logger.error("detect failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }
    }

    /// Live swap: install the detector for the shared selection's `entry`. The
    /// running loop picks it up on its next frame — no camera/session restart.
    /// A no-op-equivalent when capture isn't live (the loop reads `detector`
    /// only while running; `start` re-resolves the shared selection anyway).
    func updateDetector(for entry: DetectorCatalogEntry?) {
        detector = Self.resolveDetector(for: entry)
        installedDetectorID = entry?.id
    }

    /// Resolve a catalog entry into the concrete detector to run. Mirrors the
    /// other pages: the entry's factory is the single source of truth for how a
    /// detector is built (reusing the `DemoModelStore` warm cache for bundled /
    /// picked Core ML models, since the factories read it). Building the
    /// `ActiveDetectorSession` only to read `router.currentDetector` has no
    /// cache side effect. Falls back to the default Vision detector when the
    /// entry is `nil` or its router yields no detector.
    private static func resolveDetector(for entry: DetectorCatalogEntry?) -> any Detector {
        guard let entry else { return defaultDetector }
        let session = entry.makeSession(ResultStore())
        return session.router.currentDetector ?? defaultDetector
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
