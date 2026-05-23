@preconcurrency import AVFoundation
import Iris
import SwiftUI
import os

/// Top-level shell for the iOS demo. Two tabs:
///
/// - **Capture** — M2 Phase 7's live camera → Vision rectangle detector →
///   `DetectionLayer` overlay (preserved exactly from the pre-M3-Phase-6
///   `ContentView`, now factored into `CaptureContentView`).
/// - **Playback** — M3 Phase 6's parity smoke. Auto-loads the bundled
///   fixture clip (`clipboard-blank-page.mp4` — the same one Phase 1's
///   tests use), drives `PlaybackView` + `Scrubber` + `DetectionLayer`
///   with no file picker (per the brief — iOS uses a bundled resource,
///   macOS uses `.fileImporter`).
///
/// The tab structure exists to prove the playback subsystem is *not*
/// macOS-only — per the locked `plans/DECISIONS.md` §"macOS parity is a
/// *principle*, not a target" decision, the same `PlaybackSource`/
/// `PlaybackView`/`Scrubber`/`PlayerLayerConverter` stack must work
/// unchanged on iOS.
struct ContentView: View {
    var body: some View {
        TabView {
            CaptureContentView()
                .tabItem {
                    Label("Capture", systemImage: "camera")
                }

            PlaybackContentView()
                .tabItem {
                    Label("Playback", systemImage: "play.rectangle")
                }
        }
    }
}

// MARK: - Capture tab (preserved M2 Phase 7 behavior)

/// Live camera → Vision rectangle detector → `ResultStore` →
/// `DetectionLayer` overlay, full-screen. Run on a physical iPhone
/// (iOS 26+) — the simulator has no camera hardware.
///
/// This was the entire `ContentView` body pre-M3-Phase-6; it's been lifted
/// into its own view so the new top-level `ContentView` can host both
/// Capture and Playback tabs. The code path is identical to what M2
/// Phase 7 shipped.
struct CaptureContentView: View {
    @State private var session: CaptureSession?
    @State private var resultStore = ResultStore()
    @State private var converter: PreviewLayerConverter?
    @State private var errorText: String?

    var body: some View {
        ZStack {
            if let session {
                CameraPreview(
                    source: session.previewSource,
                    videoGravity: .resizeAspectFill,
                    onPreviewLayerReady: { layer in
                        Task { @MainActor in
                            converter = PreviewLayerConverter(previewLayer: layer)
                        }
                    }
                )
                .ignoresSafeArea()

                if let converter {
                    DetectionLayer(
                        store: resultStore,
                        converter: converter,
                        videoRect: .zero  // unused by PreviewLayerConverter
                    )
                    .ignoresSafeArea()
                }
            } else if let errorText {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text(errorText)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            } else {
                ProgressView("Starting capture…")
            }
        }
        .task {
            let new = CaptureSession()
            do {
                try await new.start()
            } catch {
                let message = "Capture start failed: \(error)"
                Logger.demo.error("\(message, privacy: .public)")
                errorText = message
                return
            }
            session = new

            // Vision default `maximumAspectRatio` of 0.5 only accepts narrow
            // rects (Phase 3 footgun). 1.0 accepts squares too;
            // `minimumConfidence: 0.5` filters out the noisy long-tail.
            let detector = VisionRectanglesDetector(
                minimumAspectRatio: 0.3,
                maximumAspectRatio: 1.0,
                minimumSize: 0.1,
                minimumConfidence: 0.7,
                label: "rect"
            )

            for await frame in new.frames {
                do {
                    let detections = try await detector.detect(in: frame)
                    resultStore.append(
                        TimestampedDetections(timestamp: frame.timestamp, detections: detections)
                    )
                } catch {
                    let message = String(describing: error)
                    Logger.demo.error("detect failed: \(message, privacy: .public)")
                }
            }
        }
        .onDisappear {
            teardown()
        }
    }

    /// Tear down the `CaptureSession` when the Capture tab disappears
    /// (e.g. user switches to the Playback tab).
    ///
    /// Without this, the underlying `AVCaptureSession` stays alive while
    /// the view is offscreen — iOS posts `videoDeviceNotAvailableInBackground`
    /// (and sometimes `videoDeviceInUseByAnotherClient` if the system
    /// briefly hands the camera elsewhere), the interruption-recovery path
    /// logs both, and on tab return a *second* `CaptureSession` races the
    /// still-alive first one. Net effect: spurious interruption logs and
    /// noticeable detection gaps after switching tabs.
    ///
    /// `invalidate()` stops AVF + finishes the frame stream, so the
    /// detector's `for await` exits naturally. The `.task` modifier's own
    /// cancellation only stops the Swift task — it doesn't stop AVF.
    @MainActor
    private func teardown() {
        let priorSession = session
        session = nil
        converter = nil
        resultStore.clear()
        errorText = nil

        if let priorSession {
            Task {
                await priorSession.invalidate()
            }
        }
    }
}

// MARK: - Playback tab (M3 Phase 6 parity smoke)

/// Bundled-fixture playback → Vision rectangle detector → `ResultStore` →
/// `DetectionLayer` overlay + `Scrubber`. Mirrors `IrisDemo-macOS`'s
/// playback wiring (M3 Phase 5), differing only in source URL: the iOS
/// demo loads `clipboard-blank-page.mp4` from `Bundle.main` (no file
/// picker per the brief) while macOS uses `.fileImporter`.
///
/// Lifecycle is simpler than the macOS demo's: there's no security-scoped
/// resource to acquire (the asset is inside the app bundle), and no swap
/// flow (the clip is fixed for the lifetime of the tab). Teardown still
/// cancels the detector task and `invalidate()`s the source on view
/// disappear so the AVF observers and frame stream don't leak.
///
/// `videoRect` for `DetectionLayer` is read from `playerLayer.videoRect`
/// each TimelineView tick — same pattern as the macOS demo (M3 Phase 5).
struct PlaybackContentView: View {
    @State private var controller: PlaybackController?
    @State private var resultStore = ResultStore()
    @State private var converter = PlayerLayerConverter()
    @State private var playerLayer: AVPlayerLayer?
    @State private var detectionTask: Task<Void, Never>?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            if let controller {
                playbackArea(controller: controller)

                Scrubber(model: controller)
                    .background(Color(.systemBackground))
            } else if let errorText {
                errorView(errorText)
            } else {
                ProgressView("Loading fixture…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            loadFixture()
        }
        .onDisappear {
            teardown()
        }
    }

    // MARK: - Sub-views

    /// `PlaybackView` + `DetectionLayer` stack. Mirrors the macOS demo's
    /// `playbackArea(controller:)` — the overlay is conditional on
    /// `playerLayer` because `PlayerLayerConverter` needs the AVF layer
    /// to compute `videoRect`.
    @ViewBuilder
    private func playbackArea(controller: PlaybackController) -> some View {
        ZStack {
            PlaybackView(source: controller.source) { layer in
                // `onPlayerLayerReady` fires inside `makeUIView`. Deferring
                // the `@State` write one runloop tick avoids SwiftUI's
                // "modifying state during view update" warning.
                Task { @MainActor in
                    self.converter = PlayerLayerConverter(playerLayer: layer)
                    self.playerLayer = layer
                }
            }

            if let playerLayer {
                // Same per-tick `playerLayer.videoRect` read as the macOS
                // demo — propagates aspect / resize changes without KVO.
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
                    DetectionLayer(
                        store: resultStore,
                        converter: converter,
                        videoRect: playerLayer.videoRect,
                        stalenessThreshold: resultStore.playbackStalenessThreshold,
                        displayTimeSource: { [controller] in
                            controller.currentTime
                        }
                    )
                    .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Lifecycle

    /// Resolve the bundled fixture URL, construct controller + detector
    /// pipeline, kick off playback. Called once from the view's `.task`.
    @MainActor
    private func loadFixture() {
        guard
            let url = Bundle.main.url(
                forResource: PlaybackContentView.fixtureName,
                withExtension: PlaybackContentView.fixtureExtension
            )
        else {
            let message = """
                Bundled fixture \(PlaybackContentView.fixtureName).\
                \(PlaybackContentView.fixtureExtension) not found in app bundle. \
                Check Apps/project.yml — the iOS target should reference \
                Tests/IrisTests/Fixtures/clipboard-blank-page.mp4 as a resource.
                """
            Logger.demo.error("\(message, privacy: .public)")
            errorText = message
            return
        }

        let source = PlaybackSource(url: url)
        let newController = PlaybackController(source: source)
        let detector = VisionRectanglesDetector(
            minimumAspectRatio: 0.3,
            maximumAspectRatio: 1.0,
            minimumSize: 0.1,
            minimumConfidence: 0.7,
            label: "rect"
        )

        // Spawn detector loop. Same shape as the macOS demo's
        // `openVideo(at:)` — `resultStore` is `@MainActor`, hop on each
        // append.
        let store = resultStore
        let task = Task {
            for await frame in source.frames {
                if Task.isCancelled { break }
                do {
                    let detections = try await detector.detect(in: frame)
                    await MainActor.run {
                        store.append(
                            TimestampedDetections(
                                timestamp: frame.timestamp,
                                detections: detections
                            )
                        )
                    }
                } catch {
                    Logger.demo.error(
                        "detect failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }

        self.controller = newController
        self.detectionTask = task
        self.errorText = nil
        self.playerLayer = nil  // re-bound when PlaybackView attaches

        // Kick off playback. `togglePlay()` transitions `.idle` → `.running`.
        newController.togglePlay()
    }

    /// Tear down the playback session on view-disappear. Order: cancel
    /// detector → invalidate source. No security-scoped resource here
    /// since the asset lives in the app bundle.
    @MainActor
    private func teardown() {
        detectionTask?.cancel()
        detectionTask = nil

        let priorSource = controller?.source
        controller = nil
        playerLayer = nil
        resultStore.clear()

        if let priorSource {
            Task {
                await priorSource.invalidate()
            }
        }
    }

    // MARK: - Fixture resource

    /// Bundled fixture (from `Tests/IrisTests/Fixtures/`, referenced by
    /// the iOS target via `project.yml`'s `buildPhase: resources`).
    private static let fixtureName = "clipboard-blank-page"
    private static let fixtureExtension = "mp4"
}

extension Logger {
    fileprivate static let demo = Logger(subsystem: "iris.demo", category: "phase6")
}
