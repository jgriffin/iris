@preconcurrency import AVFoundation
import Iris
import SwiftUI
import UniformTypeIdentifiers
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
/// `PlaybackView`/`Scrubber`/`VideoGeometry` stack must work
/// unchanged on iOS.
struct ContentView: View {
    var body: some View {
        // Playback first ⇒ leftmost + default selection (tab order picks it).
        // `.sidebarAdaptable` renders as a bottom bar on iPhone and a left
        // sidebar on iPad / Mac (Designed for iPad). Value-based `Tab(...)`
        // API (iOS 18+; baseline is iOS 26) replaces the old `.tabItem`
        // modifier — see plans/features/demo-sim-runnable.md P1.
        TabView {
            Tab("Playback", systemImage: "play.rectangle") {
                PlaybackContentView()
            }

            Tab("Capture", systemImage: "camera") {
                CaptureContentView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
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

    /// Whether this environment has a video capture device at all. `nil` on the
    /// iOS Simulator and Mac (Designed for iPad) — both lack camera hardware.
    /// One runtime check covers `#if targetEnvironment(simulator)` *and*
    /// `ProcessInfo.isiOSAppOnMac`. On a physical iPhone this is non-nil and the
    /// capture path runs unchanged. See plans/features/demo-sim-runnable.md P2.
    private var cameraAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    var body: some View {
        ZStack {
            if !cameraAvailable {
                cameraUnavailableView
            } else if let session {
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
                        // Capture: AVF owns the geometry off the live preview
                        // layer, so the measured size is ignored.
                        makeConverter: { _ in converter }
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
            // No camera hardware (Simulator / Mac Designed for iPad): never
            // start a session — the informational fallback page is shown
            // instead. Early-return before any AVF work so there's no failed
            // start or hang. P2.
            guard cameraAvailable else { return }

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
            // rects (Phase 3 footgun). 1.0 accepts squares too. (M5 removed
            // the `minimumConfidence` knob — Vision rectangles carry no
            // probabilistic confidence, so it filtered nothing.)
            //
            // M5·P4 scope note: the capture tab is intentionally left on the
            // hardcoded rectangles detector. The catalog-driven detector
            // picker + tuning lives only in the *playback* path
            // (`PlaybackContentView`); rewiring capture is out of scope.
            let detector = VisionRectanglesDetector(
                minimumAspectRatio: 0.3,
                maximumAspectRatio: 1.0,
                minimumSize: 0.1,
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

    /// Informational page shown when no camera is available (Simulator / Mac
    /// Designed for iPad). Purely informational — no session is started; the
    /// user can switch to the Playback tab to work with video files. P2.
    @ViewBuilder
    private var cameraUnavailableView: some View {
        ContentUnavailableView {
            Label("Camera isn't available here", systemImage: "camera.fill")
        } description: {
            Text(
                """
                The Simulator and Mac (Designed for iPad) have no camera. \
                Run on a physical iPhone to use Capture. Use the Playback tab \
                to work with video files.
                """
            )
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
/// strictly **after** the coordinator's `setSource`/`teardown` `await`
/// returns — i.e. after the prior source's `invalidate()` — honoring the
/// coordinator's sandbox-scope ordering contract (AVF must not read from a
/// URL whose scope was already dropped). `scopedURL` holds the
/// currently-scoped URL (nil if the active source is the bundled fixture);
/// `loadFixture()` (no scope) and `swapToExternal(url:)` are the entry
/// points that keep start/stop balanced.
///
/// `RecentVideos` is bound via `@Bindable` so SwiftUI re-renders when the
/// MRU list mutates. The model lives at the tab level (one instance per
/// `PlaybackContentView`); swapping tabs creates a fresh view but
/// `UserDefaults` persistence makes it look identical.
struct PlaybackContentView: View {
    /// Owns the playback detection-session orchestration: the per-source detect
    /// loop, the `ResultStore` + `DetectionMetrics`, the `PlaybackController`,
    /// and the `ActiveDetectorSession` (with its self-wired pause-emit hook).
    /// The demo keeps only app-specific concerns (file picking, security scope,
    /// MRU, the bundled-fixture choice, the detector catalog + custom-model UX)
    /// and binds its library views to this coordinator's outputs. Replaces the
    /// prior per-`@State` `controller` / `resultStore` / `detectionTask` /
    /// `metrics` / `session` glue (the duplicated
    /// `buildSessionAndStartDetection` / `swapDetector` / loop-respawn dance,
    /// which the single-iteration `AsyncStream` made non-functional — see
    /// `PlaybackDetectionCoordinator`).
    @State private var coordinator = PlaybackDetectionCoordinator()
    @State private var errorText: String?

    /// M7·P2: flagging. One `FlaggingModel` wired to the coordinator (which
    /// conforms to `FlaggingSource`) over a `FlagStore` rooted at the app's
    /// Documents dir (browsable in Files.app via the file-sharing work).
    /// Built lazily in `.task` because the model holds its source `unowned`
    /// and `@State` defaults can't reference the sibling `coordinator`.
    /// `setAsset` runs after every source swap; the flagged-frames list shows
    /// in a sheet (`showFlags`).
    @State private var flaggingModel: FlaggingModel?

    /// M7·P4: the `FlagStore` shared by `flaggingModel` (writes flags) and
    /// `exportCoordinator` (reads them to export frames). Held at this level —
    /// instead of inline inside the `FlaggingModel` init — so the exporter can
    /// be handed the SAME instance. Built lazily in `.task` alongside the model.
    @State private var flagStore: FlagStore?

    /// M7·P4: owns the `FrameExporter` + sink and runs the export sweep
    /// (resolve `RecentVideos` → hold security scope → sweep). Shared wiring
    /// lives in `Apps/Shared/FrameExportCoordinator`. Built lazily once the
    /// store + MRU exist.
    @State private var exportCoordinator: FrameExportCoordinator?

    /// M7·P4: observe scene transitions to trigger sweeps at idle (background /
    /// inactive) and cancel any in-flight sweep on returning to the foreground.
    @Environment(\.scenePhase) private var scenePhase

    /// Whether the flagged-frames sheet is presented.
    @State private var showFlags = false

    /// M5·P4: the general detector-selection layer. `catalog` lists the
    /// selectable detectors (built-in Vision rectangles + body pose);
    /// `selectedDetectorID` is the picker binding. The active session
    /// (type-erased detector + its capability-derived settings view) now lives
    /// on `coordinator.session`, rebuilt by `coordinator.setSource` and
    /// `coordinator.selectDetector`. The demo never names a concrete detector
    /// or tuning view in the playback path — it goes through the catalog,
    /// resolving the selection into a `DetectorCatalogEntry` (see
    /// `resolvedEntry`) and handing that to the coordinator. Rectangles is the
    /// default so pre-M5 behavior is preserved until the user picks Body Pose.
    // M6·P2: the demo catalog adds the converted Core ML YOLOv12n detector
    // (bundled `.mlpackage`, located in `Bundle.main`) after the built-in
    // Vision detectors. Computed so the bundle lookup stays cheap (it only
    // checks the resource exists; the model is compiled lazily inside the
    // entry's session factory). The YOLO entry is omitted if the resource is
    // missing — the picker still works with the Vision detectors.
    // M6·P3: the catalog is now a function of `modelStore` (bundled warm-up
    // cache + file-picked slot). The bundled YOLO entries appear when present;
    // the file-picked `coreml.custom` slot is always listed (placeholder until
    // the user supplies a model).
    private var catalog: DetectorCatalog { DemoCatalog.detectors(store: modelStore) }
    @State private var selectedDetectorID: String = "vision.rectangles"

    /// Resolve the current picker selection into a catalog entry, falling back
    /// to the first entry. The single point where the demo turns a selection
    /// (after any custom-model load) into the `DetectorCatalogEntry` it hands
    /// the coordinator.
    private var resolvedEntry: DetectorCatalogEntry? {
        catalog.entries.first(where: { $0.id == selectedDetectorID })
            ?? catalog.entries.first
    }

    /// M6·P3: holds the bundled-model warm-up cache + the file-picked detector.
    /// `@Observable` so the picker re-renders when the custom slot loads.
    @State private var modelStore = DemoModelStore()

    /// M6·P3: presents the Core ML model document picker (`.mlpackage` /
    /// `.mlmodel`).
    @State private var showModelPicker = false

    /// Whether the tuning sheet is presented. Gear-icon toolbar button
    /// flips this on the Playback tab; the sheet hosts the active
    /// session's capability-derived `settingsView`.
    @State private var showTuning = false

    /// The URL currently held under a security scope, if any. nil when the
    /// active source is the bundled fixture (no scope needed). Every
    /// transition that mutates this must balance start/stop in pairs —
    /// see `swapToExternal(url:)` and `teardown()`.
    @State private var scopedURL: URL?

    /// MRU model. Persists across tab disappears via `UserDefaults`.
    @State private var recentVideos = RecentVideos()

    /// MRU of recently-selected detectors. Drives the launch selection (most
    /// recent that still exists in the catalog) and the picker's order (recent
    /// floats to top). Persists across launches via `UserDefaults`.
    @State private var recentDetectors = RecentDetectors()

    /// Document-picker sheet binding.
    @State private var showPicker = false

    /// Display-only: human-readable label of the active source. "Bundled
    /// fixture" when fixture; the URL's last path component otherwise.
    @State private var activeLabel: String = ""

    var body: some View {
        NavigationStack {
            playbackBody
                .toolbar {
                    // M7·P2: open the flagged-frames list. Disabled until a
                    // source is loaded (no asset → nothing to list).
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showFlags = true
                        } label: {
                            Label("Flagged frames", systemImage: "bookmark.circle")
                        }
                        .disabled(flaggingModel?.asset == nil)
                        .accessibilityLabel("Flagged frames")
                    }
                }
        }
    }

    @ViewBuilder
    private var playbackBody: some View {
        VStack(spacing: 0) {
            if let controller = coordinator.controller {
                playbackArea(controller: controller)

                // M7·P2: flag marker rail directly above the stock scrubber,
                // padded to roughly line up with the slider track. Maps each
                // flag's PTS to an x-fraction of the controller's duration.
                if let flaggingModel {
                    FlagMarkerStrip(model: flaggingModel, duration: controller.duration)
                        .padding(.horizontal, 16)
                        .background(Color(.systemBackground))
                }

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
        // M7·P2: flagged-frames list sheet — tap to jump, swipe to delete.
        .sheet(isPresented: $showFlags) {
            if let flaggingModel {
                NavigationStack {
                    VStack(spacing: 0) {
                        FlaggedFramesList(model: flaggingModel)
                        // M7·P4: manual export trigger + last-run status. Forces
                        // a sweep through the SAME path the launch / background
                        // triggers use — the easiest way to confirm `frames/`
                        // fills up.
                        exportFooter
                    }
                    .navigationTitle("Flagged frames")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showFlags = false }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            DocumentPicker { url in
                showPicker = false
                swapToExternal(url: url)
            }
            .ignoresSafeArea()
        }
        // M6·P3: Core ML model document picker. On pick, load + prewarm via the
        // store, then re-select the custom entry so the existing swap flow runs
        // the freshly-loaded detector.
        .sheet(isPresented: $showModelPicker) {
            DocumentPicker(contentTypes: Self.modelContentTypes) { url in
                showModelPicker = false
                loadPickedModel(at: url)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showTuning) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        // M5·P5: the tuning sheet scrolls three regions
                        // separated by rules — Tuning leads at the TOP; Live
                        // detections takes the generous middle (it's the
                        // focus); Metrics anchors the BOTTOM. `Divider()`s mark
                        // the region boundaries and the wider `spacing` keeps it
                        // from reading as jammed-together. The detector picker
                        // is now a top-level control in `controlBar` (always
                        // visible without opening this sheet); changing it
                        // rebuilds `session` + restarts the loop (see
                        // `.onChange(of: selectedDetectorID)`). Live detections
                        // is the `DetectionInspector` reading the SAME
                        // `resultStore.lookup` the overlay reads; Metrics is the
                        // verbose gauge.

                        // The session's `settingsView` is itself a `Form`,
                        // which doesn't compose inside a ScrollView. Show it
                        // only when present, in its own fixed-height frame so
                        // the surrounding scroll owns the gesture.
                        if let session = coordinator.session {
                            sheetSection("Tuning") {
                                session.settingsView
                                    .frame(minHeight: 240)
                            }
                        }

                        Divider()

                        // Live detections — same lookup the overlay reads.
                        // The focus of the sheet: given a generous `minHeight`
                        // so it reads as room to breathe, not a cramped row.
                        sheetSection("Live detections") {
                            if let controller = coordinator.controller {
                                DetectionInspector(
                                    store: coordinator.resultStore,
                                    displayTimeSource: { [controller] in
                                        controller.currentTime
                                    },
                                    stalenessThreshold: coordinator.resultStore.playbackStalenessThreshold
                                )
                            } else {
                                Text("Open a video to inspect detections.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: 280, alignment: .top)

                        Divider()

                        sheetSection("Metrics") {
                            DetectionMetricsView(metrics: coordinator.metrics)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("Detector tuning")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showTuning = false }
                    }
                }
            }
        }
        .task {
            // M7·P2: build the flagging model once, wired to the coordinator
            // (which conforms to `FlaggingSource`) over a Documents-dir store.
            // The model holds the coordinator `unowned`; both are `@State` on
            // this view, so the coordinator outlives the model.
            if flaggingModel == nil {
                let documents = FileManager.default
                    .urls(for: .documentDirectory, in: .userDomainMask).first!
                // M7·P4: build the store ONCE and share it between the flagging
                // model (writer) and the export coordinator (reader) so the
                // sweep exports exactly the flags the UI sets.
                let store = FlagStore(baseDir: documents)
                flagStore = store
                flaggingModel = FlaggingModel(store: store, source: coordinator)
                let exporter = FrameExportCoordinator(
                    store: store,
                    baseDir: documents,
                    recentVideos: recentVideos
                )
                exportCoordinator = exporter
                // No launch-trigger sweep: it contends with the user
                // immediately opening/playing a video (the sweep opens headless
                // PlaybackSources). Background (scenePhase) + manual button only.

                // CHANGE 2: launch selection from the detector MRU — the most
                // recent detector that still exists in the catalog. Falls back
                // to the catalog's first entry (preserving the prior default)
                // when the MRU is empty or all-stale. Gated on the same
                // first-build guard so it runs once and doesn't clobber a
                // mid-session selection.
                if let mru = recentDetectors.firstAvailable(in: catalog) {
                    selectedDetectorID = mru
                } else if let first = catalog.entries.first {
                    selectedDetectorID = first.id
                }
            }
            // First-launch / first-appear behavior: if the user hasn't
            // picked anything yet AND the MRU is empty, fall back to the
            // bundled fixture. `coordinator.controller` being non-nil means
            // we've already loaded *something* (re-appear after a tab switch
            // would already have a controller... except `onDisappear`
            // tears it down, so re-appear hits this path too).
            if coordinator.controller == nil {
                loadFixture()
            }
            // M6·P3: warm the bundled Core ML models off the main actor at
            // launch so the first selection isn't a cold compile/load stall.
            await modelStore.prewarmBundledModels()
        }
        .onChange(of: selectedDetectorID) {
            // M6·P3: selecting the unloaded file-pick slot opens the model
            // picker right away (in addition to the explicit button).
            if selectedDetectorID == DemoCatalog.customEntryID,
                modelStore.availability(forEntryID: DemoCatalog.customEntryID) == .modelNotReady
            {
                showModelPicker = true
            }
            // Remember + float the selection so it leads the picker next time
            // and becomes the launch default.
            recentDetectors.addOrPromote(id: selectedDetectorID)
            swapDetector()
        }
        .onDisappear {
            teardown()
        }
        // M7·P4: dataset-export triggers. Background / inactive → kick a sweep
        // (the "runs dependably at idle/close" requirement); returning to active
        // → cancel any in-flight sweep (cheap; resumes via the sink's dedup).
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                exportCoordinator?.triggerSweep()
            case .active:
                exportCoordinator?.cancelInFlight()
            @unknown default:
                break
            }
        }
    }

    // MARK: - Control bar + MRU list

    /// Detector picker + "Tune" + "Pick video" — the persistent control row
    /// below the scrubber. The detector picker is the leading control as an
    /// always-visible, quick-access switch (the user changes detectors a lot);
    /// a `.menu`-style picker shows the current detector name and stays compact
    /// on phone-sized screens. The "Load model…" button + error caption for
    /// the custom-model flow sit just below the row (see `customModelRow`) so
    /// they're reachable at top level without opening the sheet.
    @ViewBuilder
    private var controlBar: some View {
        VStack(spacing: 4) {
            HStack {
                // Always-visible detector picker — leads the row.
                Picker("Detector", selection: $selectedDetectorID) {
                    ForEach(recentDetectors.sortedEntries(catalog)) { entry in
                        detectorRow(for: entry).tag(entry.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Active detector")

                Spacer()

                // M5·P4: live tuning sheet over the active session's
                // capability-derived settings view (Tuning → Live detections →
                // Metrics). The gear is enabled even without a session.
                Button {
                    showTuning = true
                } label: {
                    Label("Tune", systemImage: "slider.horizontal.3")
                        .labelStyle(.iconOnly)
                }
                .controlSize(.small)
                .accessibilityLabel("Tune detector")

                Button {
                    showPicker = true
                } label: {
                    Label("Pick video", systemImage: "folder.badge.plus")
                }
                .controlSize(.small)
            }

            customModelRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }

    /// Custom-model affordances, shown just below the control row so the
    /// file-pick flow stays reachable at top level (the iOS control area has
    /// more room than a macOS toolbar). When the custom slot is selected but
    /// unloaded, a "Load model…" button opens the Core ML document picker (the
    /// `.onChange(of: selectedDetectorID)` auto-open also fires). A failed load
    /// surfaces a small caption so the error stays visible.
    @ViewBuilder
    private var customModelRow: some View {
        if selectedDetectorID == DemoCatalog.customEntryID,
            modelStore.availability(forEntryID: DemoCatalog.customEntryID) == .modelNotReady
        {
            HStack {
                Button {
                    showModelPicker = true
                } label: {
                    Label("Load model…", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
                Spacer()
            }
        }
        if let modelError = modelStore.pickedModelError {
            HStack {
                Text(modelError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
            }
        }
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

    /// M7·P4: "Export now" button + last-run status line, shown below the
    /// flagged-frames list. Forces a sweep through the coordinator (the same
    /// code path the launch / background triggers use); the resulting `Summary`
    /// is surfaced as a one-line `written · skipped · unreachable` status.
    @ViewBuilder
    private var exportFooter: some View {
        if let exportCoordinator {
            VStack(spacing: 6) {
                Divider()
                HStack {
                    Button {
                        Task { await exportCoordinator.exportNow() }
                    } label: {
                        Label("Export now", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(exportCoordinator.isSweeping)

                    if exportCoordinator.isSweeping {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                if let summary = exportCoordinator.lastSummary {
                    Text(summary.demoStatusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
        }
    }

    // MARK: - Sub-views

    /// One labeled section in the stacked tuning sheet: a headline title over
    /// its content. Keeps the four sections (Detector / Tuning / Metrics /
    /// Live detections) visually uniform.
    @ViewBuilder
    private func sheetSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `PlaybackView` + `DetectionLayer` stack. Mirrors the macOS demo's
    /// `playbackArea(controller:)`. Player + overlay share the SAME
    /// `ZStack` frame, and `PlaybackView` is locked to `.resizeAspect`
    /// (centered aspect-fit). The overlay's own `GeometryReader` measures
    /// that shared frame, so `VideoGeometry(contentSize: presentationSize,
    /// containerSize: <that frame>, .aspectFit).displayRect` lands exactly
    /// on the on-screen video. `presentationSize` is read at draw time
    /// inside the converter closure (not in this body), and the overlay
    /// self-suppresses while it's zero (`displayRect == .zero`).
    @ViewBuilder
    private func playbackArea(controller: PlaybackController) -> some View {
        ZStack {
            PlaybackView(source: controller.source)
                // Pin the representable's identity to the source's lifetime so
                // sibling/parent re-evaluation can never re-make it (which would
                // tear down the AVPlayerLayer + restart the tick driver mid-play).
                .id(ObjectIdentifier(controller.source))

            // Always present. `presentationSize` is read INSIDE the closure,
            // which runs at draw time in `DetectionLayer`'s own
            // `GeometryReader` — NOT in this body. That keeps `presentationSize`
            // (a KVO-driven `@Observable` AVF can re-publish on seeks/stalls)
            // from re-evaluating the slot holding `PlaybackView`. Until the
            // size is non-zero, `VideoGeometry.displayRect` is `.zero`, so the
            // overlay self-suppresses — no conditional branch toggling next to
            // the player.
            DetectionLayer(
                store: coordinator.resultStore,
                makeConverter: { [controller] size in
                    // `makeConverter` runs at draw time inside DetectionLayer's
                    // GeometryReader, which SwiftUI evaluates on MainActor — so
                    // reading the MainActor-isolated controller is safe. Assert
                    // it to satisfy the `@Sendable` signature without a hop.
                    MainActor.assumeIsolated {
                        VideoGeometry(
                            contentSize: controller.presentationSize,
                            containerSize: size,
                            contentMode: .aspectFit
                        )
                    }
                },
                stalenessThreshold: coordinator.resultStore.playbackStalenessThreshold,
                tuning: coordinator.session?.router,
                displayTimeSource: { [controller] in
                    // Same MainActor draw-time guarantee as `makeConverter`.
                    MainActor.assumeIsolated { controller.currentTime }
                }
            )
            .allowsHitTesting(false)

            // Best-effort pipeline gauge HUD: avg inference ms · effective
            // detections/s · drop %. Top-trailing pill, subtle material so
            // it doesn't obstruct the video. Always-on dev/eval readout.
            metricsHUD
        }
        // M7·P2: on-frame bookmark affordance, pinned to the top-right corner
        // of the actual video IMAGE (via `VideoRectAligned` through the same
        // `VideoGeometry` authority the overlay draws boxes with) — so it rides
        // the frame, clear of the letterbox/pillarbox bars and the metrics HUD.
        // Primary flag control after the P2-revision; the marker rail is a
        // secondary overview and the toolbar `bookmark.circle` opens the list.
        .overlay {
            if let flaggingModel {
                VideoRectAligned(
                    contentSize: controller.presentationSize,
                    alignment: .topTrailing
                ) {
                    FlagButton(model: flaggingModel)
                        .padding(12)
                }
            }
        }
    }

    /// Top-trailing HUD pill showing the best-effort pipeline gauge.
    @ViewBuilder
    private var metricsHUD: some View {
        VStack {
            HStack {
                Spacer()
                Text(coordinator.metrics.compactSummary)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
            Spacer()
        }
        .allowsHitTesting(false)
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

    /// Resolve the bundled fixture URL and load it as the active source via
    /// the coordinator. Called once from the view's `.task` on first appear
    /// (and on re-appear after a tab-switch teardown). The bundled asset lives
    /// inside the app bundle — **no security scope** to acquire, so no
    /// `start/stopAccessingSecurityScopedResource` for this path; `scopedURL`
    /// stays nil while the fixture is the active source.
    @MainActor
    private func loadFixture() {
        guard let entry = resolvedEntry else { return }
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

        self.errorText = nil
        self.activeLabel = "Bundled fixture"

        let source = PlaybackSource(url: url)
        Task { @MainActor in
            // Coordinator tears down any prior source, resets cache + metrics,
            // builds the controller + session, and spawns the one detect loop.
            // It does NOT start playback.
            await coordinator.setSource(source, detector: entry)
            // M7·P2: point the flagging model at the same URL the source was
            // built from so its asset fingerprint matches the active clip.
            await flaggingModel?.setAsset(url: url)
            // Kick off playback. `togglePlay()` transitions `.idle` → `.running`.
            coordinator.controller?.togglePlay()
        }
    }

    /// Swap the active source to an external (user-picked or MRU) URL.
    ///
    /// The session-orchestration dance (detect loop, cache/metrics reset,
    /// session build, prior-source teardown) now lives in
    /// `PlaybackDetectionCoordinator`; this stays purely demo-side: resolve the
    /// detector entry, acquire the new security scope, hand the
    /// `PlaybackSource` to the coordinator, then start playback. The
    /// coordinator's `setSource` internally tears down the prior source and
    /// returns only after its `invalidate()` completes — so the **prior** scope
    /// is released strictly after that `await` (the sandbox-scope ordering
    /// contract). The new scope is acquired before `setSource` so AVF can read
    /// the new URL the moment the controller is built.
    ///
    /// Also registers `url` with `RecentVideos` so picking promotes the
    /// entry to the top of the MRU and tapping an existing MRU row
    /// re-promotes it (deduplicates inside `addOrPromote`).
    @MainActor
    private func swapToExternal(url: URL) {
        guard let entry = resolvedEntry else { return }

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
        // Wrap the model mutation in an animation transaction so the List
        // row animates its move to the top (the ForEach is keyed by stable
        // URL id, so SwiftUI can interpolate the reorder).
        withAnimation(.snappy) {
            recentVideos.addOrPromote(url)
        }

        // The prior scope (if any — nil when the bundled fixture is active)
        // outlives the coordinator's internal teardown of the prior source —
        // release it strictly AFTER `setSource` returns (which is after the
        // prior `invalidate()`).
        let priorScopedURL = scopedURL

        self.scopedURL = url
        self.activeLabel = url.lastPathComponent
        self.errorText = nil
        // The overlay keys off `coordinator.controller.presentationSize` (an
        // `@Observable` on the new controller) and the SwiftUI-measured frame —
        // no `AVPlayerLayer` handle to thread across the swap.

        let source = PlaybackSource(url: url)
        Task { @MainActor in
            // Coordinator tears down the prior source (cancel → drain →
            // invalidate), resets cache + metrics, builds the controller +
            // session, and spawns the one detect loop. It does NOT start
            // playback.
            await coordinator.setSource(source, detector: entry)

            // Prior source is now invalidated — safe to drop its scope.
            if let priorScopedURL {
                priorScopedURL.stopAccessingSecurityScopedResource()
            }

            // M7·P2: re-point the flagging model at the new URL.
            await flaggingModel?.setAsset(url: url)

            // Kick off playback through the controller so its state mirror
            // refreshes alongside the source. From `.idle`, `togglePlay()`
            // transitions to `.running`; the controller surfaces AVF errors
            // via the periodic time observer (logged to `iris.playback`).
            coordinator.controller?.togglePlay()
        }
    }

    /// M5·P4: handle a picker selection change. Resolves the newly-selected
    /// entry and hands it to the coordinator, which invalidates the cache,
    /// resets metrics, swaps the session's router in place (the live detect
    /// loop picks it up on the next frame), and re-emits the current frame so
    /// the new detector's output appears immediately even while paused.
    @MainActor
    private func swapDetector() {
        guard let entry = resolvedEntry else { return }
        Task { @MainActor in
            await coordinator.selectDetector(entry)
        }
    }

    /// Tear down the active playback session, then release the security scope
    /// (if any — nil when the bundled fixture is active). Idempotent.
    ///
    /// The coordinator's `teardown()` cancels the detect loop, drains it, and
    /// awaits `source.invalidate()` — returning only after the source is
    /// invalidated. The security-scope release is sequenced strictly AFTER that
    /// `await` (the sandbox-scope ordering contract): AVF must not read from a
    /// URL whose scope has already been dropped.
    @MainActor
    private func teardown() {
        let priorScopedURL = scopedURL
        scopedURL = nil
        activeLabel = ""
        showTuning = false
        showFlags = false
        // M7·P2: no active source → no asset to flag against.
        flaggingModel?.clearAsset()

        Task { @MainActor in
            await coordinator.teardown()
            if let priorScopedURL {
                priorScopedURL.stopAccessingSecurityScopedResource()
            }
        }
    }

    // MARK: - M6·P3 model picking

    /// Content types for the Core ML model document picker. `.mlpackage` is a
    /// directory bundle (UTI derived from its extension; conforms to
    /// `.package`); `.mlmodel` is a bare file. `.package` is appended as a
    /// fallback so `.mlpackage` directories stay selectable if the extension
    /// lookup returns nil on a given OS.
    private static let modelContentTypes: [UTType] = {
        var types: [UTType] = []
        if let pkg = UTType(filenameExtension: "mlpackage") { types.append(pkg) }
        if let model = UTType(filenameExtension: "mlmodel") { types.append(model) }
        types.append(.package)
        return types
    }()

    /// One picker row, annotated with availability. A `.modelNotReady` entry
    /// (the unloaded file-pick slot) is dimmed; everything else shows its plain
    /// display name (which for the custom slot already carries the loaded
    /// model's basename — see `DemoCatalog.customDisplayName`).
    @ViewBuilder
    private func detectorRow(for entry: DetectorCatalogEntry) -> some View {
        if modelStore.availability(forEntryID: entry.id) == .modelNotReady {
            Text(entry.displayName).foregroundStyle(.secondary)
        } else {
            Text(entry.displayName)
        }
    }

    /// Load a file-picked Path-A model, then re-select the custom entry so the
    /// existing detector-swap flow runs the freshly-loaded detector. Acquires
    /// the picked URL's security scope for the load, then releases it — the
    /// compiled model is held in memory, so no ongoing scope is needed.
    @MainActor
    private func loadPickedModel(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            await modelStore.loadPickedModel(at: url)
            if selectedDetectorID == DemoCatalog.customEntryID {
                swapDetector()
            } else {
                selectedDetectorID = DemoCatalog.customEntryID
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
