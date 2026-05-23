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

// MARK: - Playback tab (M3 Phase 6 + demo-ergonomics Phase 2)

/// Playback tab with file picker + MRU. Pipeline is unchanged from
/// M3 Phase 6 (Vision rectangle detector → `ResultStore` →
/// `DetectionLayer` + `Scrubber`); demo-ergonomics Phase 2 adds:
///
/// 1. A "Pick video" button presenting `DocumentPicker` (wraps
///    `UIDocumentPickerViewController(forOpeningContentTypes: [.movie])`).
/// 2. An MRU list backed by `RecentVideos` (Phase 1 shared model). Tap
///    a row → resolve bookmark → swap controller source.
/// 3. The bundled `clipboard-blank-page.mp4` fixture remains as the
///    first-launch default — loaded automatically if `RecentVideos` is
///    empty AND the user hasn't picked anything yet. Once the user picks
///    OR taps an MRU row, the fixture stops being the source of truth
///    for the tab.
///
/// **Security-scope accounting.** The bundled fixture is inside the app
/// bundle — no security scope needed. External URLs (picker + MRU) require
/// `startAccessingSecurityScopedResource()`; the matching `stop` runs
/// either in `teardown()` (tab disappear) or just before acquiring a new
/// scope (mid-session swap). `scopedURL` holds the currently-scoped URL
/// (nil if the active source is the bundled fixture); `swapToFixture()` /
/// `swapToExternal(url:)` are the two entry points that guarantee
/// balanced start/stop.
///
/// `RecentVideos` is bound via `@Bindable` so SwiftUI re-renders when the
/// MRU list mutates. The model lives at the tab level (one instance per
/// `PlaybackContentView`); swapping tabs creates a fresh view but
/// `UserDefaults` persistence makes it look identical.
struct PlaybackContentView: View {
    @State private var controller: PlaybackController?
    @State private var resultStore = ResultStore()
    @State private var converter = PlayerLayerConverter()
    @State private var playerLayer: AVPlayerLayer?
    @State private var detectionTask: Task<Void, Never>?
    @State private var errorText: String?

    /// The URL currently held under a security scope, if any. nil when the
    /// active source is the bundled fixture (no scope needed). Every
    /// transition that mutates this must balance start/stop in pairs —
    /// see `swapToExternal(url:)` and `teardown()`.
    @State private var scopedURL: URL?

    /// MRU model. Persists across tab disappears via `UserDefaults`.
    @State private var recentVideos = RecentVideos()

    /// Document-picker sheet binding.
    @State private var showPicker = false

    /// Display-only: human-readable label of the active source. "Bundled
    /// fixture" when fixture; the URL's last path component otherwise.
    @State private var activeLabel: String = ""

    var body: some View {
        VStack(spacing: 0) {
            if let controller {
                playbackArea(controller: controller)

                Scrubber(model: controller)
                    .background(Color(.systemBackground))

                controlBar
                mruSection
            } else if let errorText {
                errorView(errorText)
            } else {
                ProgressView("Loading fixture…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showPicker) {
            DocumentPicker { url in
                showPicker = false
                swapToExternal(url: url)
            }
            .ignoresSafeArea()
        }
        .task {
            // First-launch / first-appear behavior: if the user hasn't
            // picked anything yet AND the MRU is empty, fall back to the
            // bundled fixture. `controller` being non-nil means we've
            // already loaded *something* (re-appear after a tab switch
            // would already have a controller... except `onDisappear`
            // tears it down, so re-appear hits this path too).
            if controller == nil {
                loadFixture()
            }
        }
        .onDisappear {
            teardown()
        }
    }

    // MARK: - Control bar + MRU list

    /// "Pick video" button + a label for the active source. Sits below the
    /// scrubber; on phone-sized screens this reads cleanly as a single row.
    @ViewBuilder
    private var controlBar: some View {
        HStack {
            Text(activeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                showPicker = true
            } label: {
                Label("Pick video", systemImage: "folder.badge.plus")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }

    /// MRU list below the control bar. Empty state shows a hint to use the
    /// picker (no separate placeholder — the picker button is the CTA).
    ///
    /// `recentVideos.resolve()` is called on every render — that's a
    /// `UserDefaults` round-trip + bookmark resolution for each entry. The
    /// list is capped at ~10, so this is acceptable; promoting to a cached
    /// `@State` snapshot would buy nothing here.
    ///
    /// Swipe-to-delete is intentionally omitted. `RecentVideos` exposes no
    /// `remove(_:)` API as of Phase 1, and the Phase 2 brief says: skip
    /// swipe-to-delete rather than expand `RecentVideos` (deferred).
    @ViewBuilder
    private var mruSection: some View {
        let recents = recentVideos.resolve()
        if !recents.isEmpty {
            List {
                Section("Recent videos") {
                    ForEach(recents, id: \.self) { url in
                        Button {
                            swapToExternal(url: url)
                        } label: {
                            HStack {
                                Image(systemName: "play.rectangle")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(.primary)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .frame(maxHeight: 240)
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

    /// Resolve the bundled fixture URL and load it as the active source.
    /// Called once from the view's `.task` on first appear (and on
    /// re-appear after a tab-switch teardown). The bundled asset lives
    /// inside the app bundle — no security scope to acquire.
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

        // Bundled fixture has no security scope. Pass `acquireScope: false`
        // so `startSession(url:)` doesn't try to acquire one.
        startSession(url: url, label: "Bundled fixture", acquireScope: false)
    }

    /// Swap the active source to an external (user-picked or MRU) URL.
    ///
    /// Order matters: tear down the prior session FIRST (which releases
    /// any prior `scopedURL`), THEN acquire the new security scope and
    /// build the new controller. Reversing the order would double-scope
    /// or leak the prior scope across the swap.
    ///
    /// Also registers `url` with `RecentVideos` so picking promotes the
    /// entry to the top of the MRU and tapping an existing MRU row
    /// re-promotes it (deduplicates inside `addOrPromote`).
    @MainActor
    private func swapToExternal(url: URL) {
        // Tear down BEFORE acquiring the new scope — otherwise the prior
        // URL's scope outlives its usefulness, and a same-URL re-tap
        // would double-acquire without a matching `stop`.
        teardown()

        guard url.startAccessingSecurityScopedResource() else {
            let message = "Could not access \(url.lastPathComponent) (security scope denied)."
            Logger.demo.error(
                "startAccessingSecurityScopedResource failed for \(url.path, privacy: .public)"
            )
            errorText = message
            return
        }

        // Register in MRU. `addOrPromote` is idempotent — tapping an
        // existing MRU row moves it to the front without duplicating.
        recentVideos.addOrPromote(url)

        // `acquireScope: false` here because we already acquired it
        // ourselves above (couldn't do it inside `startSession` because
        // the guard-fail path needs to early-return on scope denial).
        startSession(url: url, label: url.lastPathComponent, acquireScope: false)
        // Record the scope so `teardown()` can balance it.
        scopedURL = url
    }

    /// Common construction path for both fixture + external sources.
    /// Builds `PlaybackController` + detector pipeline, kicks off playback.
    /// Caller is responsible for security-scope acquisition (if any) and
    /// for tearing down any prior session before invoking.
    ///
    /// `acquireScope` is currently always `false` at call sites — kept as
    /// a parameter to make the contract explicit ("this method does not
    /// touch security scope"). The two callers each handle scope in their
    /// own way (`loadFixture` skips it; `swapToExternal` acquires it
    /// before calling and assigns `scopedURL` after).
    @MainActor
    private func startSession(url: URL, label: String, acquireScope: Bool) {
        _ = acquireScope  // Documentation parameter; see doc comment.

        let source = PlaybackSource(url: url)
        let newController = PlaybackController(source: source)
        let pipeline = DetectorPipeline(
            VisionRectanglesDetector(
                minimumAspectRatio: 0.3,
                maximumAspectRatio: 1.0,
                minimumSize: 0.1,
                minimumConfidence: 0.7,
                label: "rect"
            )
        )

        // Spawn detector loop. Same shape as the macOS demo's
        // `openVideo(at:)` — the pipeline owns the cache write-through on
        // miss (playback-detection-cache Phase 2), so this loop no longer
        // calls `store.append` itself. Cache hits on revisited timestamps
        // skip the detector dispatch entirely; the overlay reads
        // `resultStore` on its own TimelineView tick.
        let store = resultStore
        let task = Task {
            for await frame in source.frames {
                if Task.isCancelled { break }
                do {
                    _ = try await pipeline.detect(in: frame, cache: store)
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
        self.activeLabel = label

        // Kick off playback. `togglePlay()` transitions `.idle` → `.running`.
        newController.togglePlay()
    }

    /// Tear down the active playback session. Idempotent.
    ///
    /// Order: cancel detector → invalidate source → release security
    /// scope. Each step releases a hold on the file URL; reversing the
    /// order would briefly let AVF read from a URL whose security scope
    /// has already been dropped. `invalidate()` is `async`, so the
    /// security-scope release runs after it inside the same `Task` to
    /// preserve ordering — mirrors the macOS demo's `teardown()` exactly.
    @MainActor
    private func teardown() {
        detectionTask?.cancel()
        detectionTask = nil

        let priorSource = controller?.source
        let priorScopedURL = scopedURL

        controller = nil
        playerLayer = nil
        scopedURL = nil
        resultStore.clear()

        // Detach AVF observers + finish the frame stream, then release the
        // security scope. Capturing `priorSource` + `priorScopedURL`
        // locally lets a follow-up `swapToExternal` reset `@State` to the
        // new session synchronously while AVF tears the old one down.
        Task {
            if let priorSource {
                await priorSource.invalidate()
            }
            if let priorScopedURL {
                priorScopedURL.stopAccessingSecurityScopedResource()
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
