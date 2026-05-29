import AppKit
import Iris
import SwiftUI
import UniformTypeIdentifiers
import os

/// M3 Phase 5 end-to-end smoke + demo-ergonomics Phase 3 MRU sidebar. File
/// playback → Vision rectangle detector → `ResultStore` → `DetectionLayer`
/// overlay + `Scrubber`, with a `NavigationSplitView` sidebar listing recent
/// picks (`RecentVideos`, the Phase 1 shared model). macOS-only target; the
/// iOS demo (Phase 2) wires the same stack with a tab-bar shape.
///
/// **Session orchestration lives in `PlaybackDetectionCoordinator`.** The
/// detect loop, `ResultStore` + `DetectionMetrics`, `PlaybackController`,
/// `ActiveDetectorSession`, and ordered teardown are owned by the library
/// coordinator (a `@State` here). This view keeps only app-specific concerns:
/// file picking, security scope, MRU, the detector catalog + custom-model UX,
/// layout — and binds its library views to the coordinator's outputs.
///
/// Lifecycle:
/// - `Open Video…` button presents an `NSOpenPanel`-backed `.fileImporter`
///   for `.movie` URLs. Sidebar rows for previously-picked clips re-open
///   them without the panel.
/// - On pick OR sidebar tap: `swapToExternal(url:)` acquires a fresh scope
///   for the new URL, registers in `RecentVideos`, builds a
///   `PlaybackSource(url:)`, calls `await coordinator.setSource(source,
///   detector:)` (which tears the prior source down internally), releases the
///   *prior* scope after that returns, then `coordinator.controller?.togglePlay()`.
/// - On view teardown: `await coordinator.teardown()` (cancel → drain →
///   `invalidate()`), THEN `stopAccessingSecurityScopedResource()`. That
///   ordering keeps the security scope alive while AVF still holds the URL.
///
/// **Security-scope accounting.** `scopedURL` holds the URL currently under
/// scope (nil when there is no active session). The coordinator never touches
/// scope — the demo owns it end-to-end and sequences every release strictly
/// AFTER the relevant coordinator `await` (`setSource` / `teardown`), honoring
/// the coordinator's sandbox-scope ordering contract. Mirrors the iOS demo's
/// Phase 2 pattern.
///
/// The `DetectionLayer`'s geometry is computed by `VideoGeometry` from the
/// controller's `presentationSize` (the upright displayed video size) and
/// the SwiftUI-measured container size — no `AVPlayerLayer.videoRect` read.
/// Player + overlay share one `.resizeAspect` (centered aspect-fit) frame,
/// so `VideoGeometry.displayRect` lands on the on-screen video; window
/// resizes propagate through the overlay's `GeometryReader` automatically.
struct ContentView: View {
    /// Owns the playback detection-session orchestration: the per-source detect
    /// loop, the `ResultStore` + `DetectionMetrics`, the `PlaybackController`,
    /// and the `ActiveDetectorSession` (with its self-wired pause-emit hook).
    /// The demo keeps only app-specific concerns (file picking, security scope,
    /// MRU, the detector catalog + custom-model UX) and binds its library views
    /// to this coordinator's outputs. Replaces the prior per-`@State`
    /// `controller` / `resultStore` / `detectionTask` / `metrics` / `session`
    /// glue (the duplicated `buildSessionAndStartDetection` / `swapDetector` /
    /// loop-respawn dance, which the single-iteration `AsyncStream` made
    /// non-functional — see `PlaybackDetectionCoordinator`).
    @State private var coordinator = PlaybackDetectionCoordinator()
    @State private var showFilePicker = false
    @State private var errorText: String?

    /// M7·P2: flagging. One `FlaggingModel` wired to the coordinator (which
    /// conforms to `FlaggingSource`) over a `FlagStore` rooted at the app's
    /// Documents dir. Built lazily in `.task` because the model holds its
    /// source `unowned` and `@State` defaults can't reference the sibling
    /// `coordinator`. `setAsset` runs after every source swap; the
    /// flagged-frames list lives in a "Flagged frames" inspector section.
    @State private var flaggingModel: FlaggingModel?

    /// M7·P4: the `FlagStore` shared by `flaggingModel` (writes flags) and
    /// `exportCoordinator` (reads them to export frames). Held at this level so
    /// the exporter gets the SAME instance. Built lazily in `.task`.
    @State private var flagStore: FlagStore?

    /// M7·P4: owns the `FrameExporter` + sink and runs the export sweep
    /// (resolve `RecentVideos` → hold security scope → sweep). Shared wiring
    /// lives in `Apps/Shared/FrameExportCoordinator`.
    @State private var exportCoordinator: FrameExportCoordinator?

    /// M7·P4: observe scene transitions to trigger sweeps at idle (background —
    /// on macOS that's all-windows-closed / hidden) and cancel any in-flight
    /// sweep on returning to the foreground.
    @Environment(\.scenePhase) private var scenePhase

    /// M6·P3: holds the bundled-model warm-up cache + the file-picked detector.
    /// `@Observable` so the picker re-renders when the custom slot loads.
    @State private var modelStore = DemoModelStore()

    /// M6·P3: presents the Core ML model importer (`.mlpackage` / `.mlmodel`).
    @State private var showModelPicker = false

    /// FIX 3 (macOS only): the sidebar row currently highlighted by the
    /// `List(selection:)` binding. Arrow keys move this highlight WITHOUT
    /// loading; a single mouse click loads via `.onTapGesture`; Enter
    /// commits the highlighted row. Kept in sync with the active video so
    /// the highlight tracks loads triggered from elsewhere.
    @State private var highlightedURL: URL?

    /// The URL currently held under a security scope, if any. nil when no
    /// session is active. Every transition that mutates this must balance
    /// `startAccessingSecurityScopedResource()` / `stop…` in pairs — see
    /// `swapToExternal(url:)` and `teardown()`.
    @State private var scopedURL: URL?

    /// MRU model. Persists across launches via `UserDefaults`; bookmark
    /// blobs carry security-scope information so re-opening a sidebar
    /// entry on next launch still gets a usable URL.
    @State private var recentVideos = RecentVideos()

    /// MRU of recently-selected detectors. Drives the launch selection (most
    /// recent that still exists in the catalog) and the picker's order (recent
    /// floats to top). Persists across launches via `UserDefaults`.
    @State private var recentDetectors = RecentDetectors()

    /// FIX 3 (macOS only): count of exported frames in
    /// `<Documents>/iris-dataset/frames/`, refreshed when the sidebar appears.
    /// `nil` until first computed. Source of truth is the `*.png` file count,
    /// which is the real "how many frames are there" answer regardless of the
    /// telemetry sidecar.
    @State private var exportedFrameCount: Int?

    /// Display-only: human-readable label of the active source. The URL's
    /// last path component when one is loaded; empty otherwise.
    @State private var activeLabel: String = ""

    /// M5·P4: the general detector-selection layer. `catalog` lists the
    /// selectable detectors (built-in Vision rectangles + body pose);
    /// `selectedDetectorID` is the toolbar picker binding. The active session
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

    /// Whether the inspector panel is showing. Gear-icon toolbar toggle
    /// flips this; the inspector hosts the active session's
    /// capability-derived `settingsView`.
    @State private var showTuning = false

    // MARK: - M8·P4: Images mode

    /// Top-level sidebar source mode. Additive over the existing playback shell:
    /// `.videos` renders the playback sidebar + detail EXACTLY as before;
    /// `.images` swaps in the still-image inspector (its own coordinator + MRU).
    /// Selected via the segmented picker at the top of the sidebar.
    private enum SourceMode: String, CaseIterable, Identifiable {
        case videos = "Videos"
        case images = "Images"
        var id: String { rawValue }
    }

    @State private var mode: SourceMode = .videos

    /// One-shot image detection orchestration for `.images` mode: a held still
    /// `Frame`, the `ResultStore` + `DetectionMetrics`, and the
    /// `ActiveDetectorSession`. Lives alongside the playback `coordinator`; only
    /// one is shown at a time per `mode`.
    @State private var imageCoordinator = ImageDetectionCoordinator()

    /// MRU of recently-opened images. The image-page sibling of `recentVideos`.
    @State private var recentImages = RecentImages()

    /// `.images`-mode picker selection. Independent of the playback selection so
    /// switching modes doesn't clobber either.
    @State private var imageSelectedDetectorID: String = "vision.rectangles"

    /// Whether the image-mode tuning sheet is presented.
    @State private var showImageTuning = false

    /// Presents the macOS image `.fileImporter`.
    @State private var showImagePicker = false

    /// The URL currently held under a security scope for `.images` mode, if any.
    @State private var imageScopedURL: URL?

    /// Last image-mode error (decode / scope), surfaced below the detail.
    @State private var imageErrorText: String?

    /// Whether the image-mode launch selection has been applied once.
    @State private var imageDidApplyLaunchSelection = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // M8·P4: top-level source-mode selector. Additive — `.videos`
                // shows the existing playback sidebar + detail unchanged;
                // `.images` swaps in the still-image inspector.
                Picker("Source", selection: $mode) {
                    ForEach(SourceMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)

                switch mode {
                case .videos:
                    sidebar
                case .images:
                    imageSidebar
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            switch mode {
            case .videos:
                detailArea
            case .images:
                imageDetail
            }
        }
        .frame(minWidth: 880, minHeight: 480)
        .inspector(isPresented: $showTuning) {
            // M5·P5: one scrolling pane, three regions separated by rules.
            // The detector picker now lives in the toolbar (always visible);
            // this pane leads with Tuning (the active session's
            // capability-derived `settingsView`), then Live detections takes
            // the generous middle (the `DetectionInspector` reading the SAME
            // `resultStore.lookup` the overlay reads, as a render/cache
            // diagnostic), then Metrics anchors the BOTTOM (verbose
            // `DetectionMetricsView`). `Divider()`s mark the boundaries and
            // the wider `spacing` keeps it from reading as jammed-together.
            // A failed custom-model load surfaces a caption above Tuning so
            // the error stays visible even though the picker moved out.
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // Custom-model load error — relocated from the (now
                    // moved-out) Detector section so a failed load is still
                    // reported. A toolbar can't host a multiline caption.
                    if let modelError = modelStore.pickedModelError {
                        Text(modelError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // 1. Tuning — the session's capability-derived settings.
                    inspectorSection("Tuning") {
                        if let session = coordinator.session {
                            session.settingsView
                        } else {
                            Text("Open a video to start tuning.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    // 2. Live detections — same lookup the overlay reads.
                    //    The focus of the pane: given a generous `minHeight`
                    //    so it reads as room to breathe, not a cramped row.
                    inspectorSection("Live detections") {
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

                    // 3. Metrics — verbose, counts-lead gauge.
                    inspectorSection("Metrics") {
                        DetectionMetricsView(metrics: coordinator.metrics)
                    }

                    Divider()

                    // 4. M7·P2: Flagged frames — the current asset's flags.
                    //    Tap a row to jump; swipe / context-menu to delete.
                    inspectorSection("Flagged frames") {
                        if let flaggingModel {
                            FlaggedFramesList(model: flaggingModel)
                                .frame(minHeight: 200)
                        } else {
                            Text("Open a video to flag frames.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar {
            // The detector picker lives in the toolbar as an always-visible,
            // quick-access control (the user switches detectors a lot). The
            // inspector hosts only Tuning / Live detections / Metrics; the
            // gear "Tune" toggle in `.primaryAction` opens it.
            ToolbarItem(placement: .navigation) {
                Picker("Detector", selection: $selectedDetectorID) {
                    ForEach(recentDetectors.sortedEntries(catalog)) { entry in
                        detectorRow(for: entry).tag(entry.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Active detector")
            }

            // M6·P3: when the file-picked slot is selected and not yet loaded,
            // surface a "Load model…" toolbar button to open the Core ML
            // importer. The `.onChange(of: selectedDetectorID)` auto-open also
            // fires, but the explicit button keeps the affordance discoverable.
            if selectedDetectorID == DemoCatalog.customEntryID,
                modelStore.availability(forEntryID: DemoCatalog.customEntryID) == .modelNotReady
            {
                ToolbarItem(placement: .navigation) {
                    Button {
                        showModelPicker = true
                    } label: {
                        Label("Load model…", systemImage: "square.and.arrow.down")
                    }
                    .help("Load a Core ML model")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showTuning.toggle()
                } label: {
                    Label("Tune", systemImage: "slider.horizontal.3")
                }
                .help("Toggle tuning inspector")
            }
        }
        .onChange(of: selectedDetectorID) {
            // M6·P3: selecting the unloaded file-pick slot opens the model
            // importer right away (in addition to the explicit button) so a
            // first selection is a one-step "pick the model" gesture.
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
        // M6·P3: warm the bundled Core ML models off the main actor at launch
        // so the first selection isn't a cold compile/load stall. Idempotent.
        .task {
            // M7·P2: build the flagging model once, wired to the coordinator
            // (which conforms to `FlaggingSource`) over a Documents-dir store.
            // The model holds the coordinator `unowned`; both are `@State` on
            // this view, so the coordinator outlives the model.
            if flaggingModel == nil {
                let documents = FileManager.default
                    .urls(for: .documentDirectory, in: .userDomainMask).first!
                // M7·P4: build the store ONCE and share it between the flagging
                // model (writer) and the export coordinator (reader).
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
                // when the MRU is empty or all-stale. Done once, here, so it
                // doesn't clobber a selection the user makes mid-session.
                if let mru = recentDetectors.firstAvailable(in: catalog) {
                    selectedDetectorID = mru
                } else if let first = catalog.entries.first {
                    selectedDetectorID = first.id
                }
            }
            await modelStore.prewarmBundledModels()
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: Self.movieContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                swapToExternal(url: url)
            case .failure(let error):
                Logger.demo.error(
                    "file picker failed: \(error.localizedDescription, privacy: .public)"
                )
                errorText = "Could not open file: \(error.localizedDescription)"
            }
        }
        // M6·P3: Core ML model importer. On pick, load + prewarm via the store,
        // then re-select the custom entry so the existing swap flow runs the
        // freshly-loaded detector.
        .fileImporter(
            isPresented: $showModelPicker,
            allowedContentTypes: Self.modelContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                loadPickedModel(at: url)
            case .failure(let error):
                Logger.demo.error(
                    "model picker failed: \(error.localizedDescription, privacy: .public)"
                )
                errorText = "Could not open model: \(error.localizedDescription)"
            }
        }
        // Tear down the active session when the view disappears so the
        // security-scoped resource is released and the AVF observers are
        // unhooked. SwiftUI calls `onDisappear` on window close. The
        // coordinator's `teardown()` is async (it drains the detect loop and
        // awaits `source.invalidate()`); the scope release is sequenced strictly
        // after it returns — see `releaseScope(after:)`.
        .onDisappear {
            teardown()
        }
        // M7·P4: dataset-export triggers. Background / inactive (all windows
        // closed / hidden on macOS) → kick a sweep; returning to active →
        // cancel any in-flight sweep (cheap; resumes via the sink's dedup).
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

    // MARK: - Sub-views

    /// One labeled section in the stacked inspector pane: a headline title
    /// over its content. Keeps the four sections (Detector / Tuning / Metrics
    /// / Live detections) visually uniform without nesting Forms.
    @ViewBuilder
    private func inspectorSection<Content: View>(
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

    /// Sidebar: "Open Video…" button + recent picks list. Empty MRU state
    /// surfaces a hint pointing at the picker button — macOS demo has
    /// always required a picked file (no bundled fixture fallback), so
    /// this is the entire affordance on first launch.
    ///
    /// `recentVideos.resolve()` is called on every render — that's a
    /// `UserDefaults` round-trip + bookmark resolution per entry. The list
    /// is capped at ~10, so this is acceptable; promoting to a cached
    /// `@State` snapshot would buy nothing here. Same approach as the iOS
    /// Phase 2 view.
    @ViewBuilder
    private var sidebar: some View {
        let recents = recentVideos.resolve()
        VStack(alignment: .leading, spacing: 0) {
            // CHANGE 1: the single, prominent open entry point. Full-width,
            // bordered-prominent, at the very top of the sidebar — replacing
            // both the old icon-only header button and the bottom-bar button.
            Button {
                showFilePicker = true
            } label: {
                Label("Open Video…", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            HStack {
                Text("Recent videos")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if recents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No recent videos")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Use Open Video… to pick a clip.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                // FIX 3: selection binds to `highlightedURL` — it ONLY
                // moves the highlight (arrow keys + single-click both update
                // it; no load side-effect in the setter). A single mouse
                // click ALSO fires `.onTapGesture` on the row → loads;
                // arrow keys move selection only (no gesture) → highlight
                // without load. Enter commits the highlighted row.
                List(selection: $highlightedURL) {
                    ForEach(recents, id: \.self) { url in
                        recentRow(url: url)
                            .tag(url)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                swapToExternal(url: url)
                            }
                    }
                }
                .listStyle(.sidebar)
                .onKeyPress(.return) {
                    if let highlightedURL {
                        swapToExternal(url: highlightedURL)
                    }
                    return .handled
                }
            }

            // CHANGE 3: dataset section pinned to the bottom of the sidebar.
            datasetSection
        }
        .onAppear { refreshExportedFrameCount() }
    }

    /// CHANGE 3 (macOS only): a small "Dataset" footer at the bottom of the
    /// sidebar — exported-frame count + a "Reveal in Finder" button pointing at
    /// the real export location (`<Documents>/iris-dataset/frames/`, the same
    /// base dir the `FrameExportCoordinator` writes to). iOS exposes Documents
    /// via Files.app, so this is macOS-only.
    @ViewBuilder
    private var datasetSection: some View {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            // Title row hosts "Export now" right-aligned (Change 1, moved here
            // from the right-hand flagged-frames panel). Forces a sweep through
            // the SAME path as the launch / background triggers.
            HStack {
                Text("Dataset")
                    .font(.headline)
                Spacer()
                if let exportCoordinator {
                    if exportCoordinator.isSweeping {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task { await exportCoordinator.exportNow() }
                    } label: {
                        Label("Export now", systemImage: "square.and.arrow.down.on.square")
                    }
                    .controlSize(.small)
                    .disabled(exportCoordinator.isSweeping)
                    .help("Export all flagged frames to the dataset folder")
                }
            }

            // Frame count is the standing total; the last-run summary (what the
            // most recent sweep added/skipped) complements it without dup'ing.
            Text(exportedFrameStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let summary = exportCoordinator?.lastSummary {
                Text(summary.demoStatusLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            Button {
                revealFramesInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .help("Open the exported frames folder in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Human-readable exported-frame status line, with a sensible empty state.
    private var exportedFrameStatus: String {
        switch exportedFrameCount {
        case .none, .some(0):
            return "No frames yet"
        case .some(1):
            return "1 frame exported"
        case .some(let n):
            return "\(n) frames exported"
        }
    }

    /// Resolve the frames dir the same way `FrameExportCoordinator` does:
    /// `<Documents>/iris-dataset/frames/`. The coordinator hands the Documents
    /// dir as `baseDir`; `FolderDatasetSink` roots `iris-dataset/frames/` under
    /// it. Resolving the same path here keeps the UI pointed at the real
    /// export location rather than inventing a second one.
    private static var framesDir: URL {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents
            .appendingPathComponent("iris-dataset", isDirectory: true)
            .appendingPathComponent("frames", isDirectory: true)
    }

    /// Count `*.png` files in the frames dir. The file count is the source of
    /// truth for "how many frames are there" (vs. the telemetry sidecar).
    /// Missing dir → 0.
    private func refreshExportedFrameCount() {
        let dir = Self.framesDir
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )) ?? []
        exportedFrameCount = urls.filter { $0.pathExtension.lowercased() == "png" }.count
    }

    /// Reveal the frames dir in Finder. Creates it first if it doesn't exist
    /// yet (so the button always lands somewhere sensible rather than no-oping
    /// before the first export), then opens it via `NSWorkspace`.
    private func revealFramesInFinder() {
        let dir = Self.framesDir
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    @ViewBuilder
    private func recentRow(url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // CHANGE 4: truncate the parent path from the BEGINNING so the
                // meaningful tail (the enclosing folder) stays visible rather
                // than the redundant "/Users/griff/…" head.
                Text(url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        // CHANGE 4: hover tooltip surfaces the full path; right-click menu
        // copies the path or reveals the file in Finder.
        .help(url.path)
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.clipboard")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
    }

    /// Right-hand detail pane. Shows the player + scrubber + bottom bar
    /// when a session is active; otherwise the empty state with a CTA.
    @ViewBuilder
    private var detailArea: some View {
        VStack(spacing: 0) {
            if let controller = coordinator.controller {
                playbackArea(controller: controller)

                // M7·P2: flag markers drawn BEHIND the stock scrubber's
                // Slider via the Scrubber `trackUnderlay` slot (no separate
                // row). The strip inherits the Slider's exact track width, so
                // its per-platform thumbInset is the only variable keeping
                // ticks under the thumb — no manual padding to guess geometry.
                Scrubber(model: controller) {
                    if let flaggingModel {
                        FlagMarkerStrip(
                            model: flaggingModel,
                            duration: controller.duration
                        )
                    }
                }
                .background(Color(.windowBackgroundColor))

                bottomBar
            } else {
                emptyState
            }
        }
    }

    /// The `PlaybackView` + `DetectionLayer` stack. Player + overlay share
    /// the SAME `ZStack` frame, and `PlaybackView` is locked to
    /// `.resizeAspect` (centered aspect-fit). The overlay's own
    /// `GeometryReader` measures that shared frame, so
    /// `VideoGeometry(contentSize: presentationSize, containerSize: <that
    /// frame>, .aspectFit).displayRect` lands exactly on the on-screen
    /// video — no `AVPlayerLayer.videoRect` read. The overlay is gated on a
    /// non-zero `presentationSize` (zero until the item is ready); window
    /// resizes flow through the `GeometryReader` automatically.
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
        }
        // M7·P2: on-frame bookmark affordance, pinned to the top-right corner
        // of the actual video IMAGE (via `VideoRectAligned` through the same
        // `VideoGeometry` authority the overlay draws boxes with) — so it rides
        // the frame, clear of the letterbox/pillarbox bars. Primary flag
        // control after the P2-revision; the marker rail is a secondary
        // overview and the inspector's "Flagged frames" section lists them.
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

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            if !activeLabel.isEmpty {
                Text(activeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Best-effort pipeline gauge: avg inference ms · effective
                // detections/s · drop %. Placeholders until samples exist.
                Text(coordinator.metrics.compactSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            if let errorText {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(errorText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Open a video file to start.")
                    .foregroundStyle(.secondary)
            }
            Button("Open Video…") { showFilePicker = true }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Lifecycle

    private static let movieContentTypes: [UTType] = [
        .movie, .mpeg4Movie, .quickTimeMovie,
    ]

    /// M6·P3: content types for the Core ML model importer. `.mlpackage` is a
    /// directory bundle, so its UTI is derived from the extension (it conforms
    /// to `.package`); `.mlmodel` is a bare file. Falling back to `.package`
    /// keeps `.mlpackage` directories selectable if the extension lookup
    /// returns nil on a given OS.
    private static let modelContentTypes: [UTType] = {
        var types: [UTType] = []
        if let pkg = UTType(filenameExtension: "mlpackage") { types.append(pkg) }
        if let model = UTType(filenameExtension: "mlmodel") { types.append(model) }
        types.append(.package)
        return types
    }()

    /// M6·P3: one picker row, annotated with availability. A `.modelNotReady`
    /// entry (the unloaded file-pick slot) is dimmed; everything else shows
    /// its plain display name. The display name itself already carries the
    /// loaded model's basename for the custom slot (see
    /// `DemoCatalog.customDisplayName`).
    @ViewBuilder
    private func detectorRow(for entry: DetectorCatalogEntry) -> some View {
        if modelStore.availability(forEntryID: entry.id) == .modelNotReady {
            Text(entry.displayName).foregroundStyle(.secondary)
        } else {
            Text(entry.displayName)
        }
    }

    /// M6·P3: load a file-picked Path-A model, then re-select the custom entry
    /// so the existing detector-swap flow runs the freshly-loaded detector.
    /// Acquires the picked URL's security scope for the load, then releases it
    /// — the compiled model is held in memory, so no ongoing scope is needed.
    @MainActor
    private func loadPickedModel(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            await modelStore.loadPickedModel(at: url)
            // Re-select to trigger swapDetector even if already selected.
            if selectedDetectorID == DemoCatalog.customEntryID {
                swapDetector()
            } else {
                selectedDetectorID = DemoCatalog.customEntryID
            }
        }
    }

    /// Swap the active source to an external (picker- or MRU-supplied) URL.
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

        // The prior scope (if any) outlives the coordinator's internal
        // teardown of the prior source — release it strictly AFTER
        // `setSource` returns (which is after the prior `invalidate()`).
        let priorScopedURL = scopedURL

        self.scopedURL = url
        self.highlightedURL = url
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

            // M7·P2: point the flagging model at the same URL the source was
            // built from so its asset fingerprint matches the active clip.
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

    /// Tear down the active playback session, then release the security scope.
    /// Idempotent.
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
        highlightedURL = nil
        activeLabel = ""
        // M7·P2: no active source → no asset to flag against.
        flaggingModel?.clearAsset()

        Task { @MainActor in
            await coordinator.teardown()
            if let priorScopedURL {
                priorScopedURL.stopAccessingSecurityScopedResource()
            }
        }
    }

}

// MARK: - M8·P4: Images mode (extracted to keep the struct body under the lint cap)
extension ContentView {
    // MARK: - M8·P4: Images mode

    fileprivate static let imageContentTypes: [UTType] = [.image]

    /// Resolve the image-mode picker selection into a catalog entry.
    fileprivate var imageResolvedEntry: DetectorCatalogEntry? {
        catalog.entries.first(where: { $0.id == imageSelectedDetectorID })
            ?? catalog.entries.first
    }

    /// `.images` sidebar: "Open Image…" button + recent-images list. Mirrors the
    /// `.videos` sidebar shape (the recent-videos rows / empty state), driven by
    /// `RecentImages`.
    @ViewBuilder
    private var imageSidebar: some View {
        let recents = recentImages.resolve()
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showImagePicker = true
            } label: {
                Label("Open Image…", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            HStack {
                Text("Recent images")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if recents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No recent images")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Use Open Image… to pick a still.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(recents, id: \.self) { url in
                        imageRecentRow(url: url)
                            .tag(url)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                pickImage(url: url)
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        // Apply the launch detector selection + warm bundled models once, when
        // the images sidebar first appears.
        .task {
            guard !imageDidApplyLaunchSelection else { return }
            imageDidApplyLaunchSelection = true
            if let mru = recentDetectors.firstAvailable(in: catalog) {
                imageSelectedDetectorID = mru
            } else if let first = catalog.entries.first {
                imageSelectedDetectorID = first.id
            }
            await modelStore.prewarmBundledModels()
        }
        // M8·P4: the image importer lives HERE, on the images sidebar — NOT
        // stacked on the root view with the movie + model importers. SwiftUI
        // honors only one `.fileImporter(isPresented:)` per view; a third stacked
        // importer silently never presents (the "Open Image… does nothing" bug).
        // Co-locating it with its trigger button is the reliable fix.
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: Self.imageContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                pickImage(url: url)
            case .failure(let error):
                Logger.demo.error(
                    "image picker failed: \(error.localizedDescription, privacy: .public)"
                )
                imageErrorText = "Could not open image: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func imageRecentRow(url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .help(url.path)
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.clipboard")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
    }

    /// `.images` detail: the shared `ImageDetailView` plus an inline error line.
    @ViewBuilder
    private var imageDetail: some View {
        VStack(spacing: 0) {
            ImageDetailView(
                coordinator: imageCoordinator,
                catalog: catalog,
                recentDetectors: recentDetectors,
                modelStore: modelStore,
                selectedDetectorID: $imageSelectedDetectorID,
                showTuning: $showImageTuning
            )
            if let imageErrorText {
                Text(imageErrorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
        .onChange(of: imageSelectedDetectorID) {
            if imageSelectedDetectorID == DemoCatalog.customEntryID,
                modelStore.availability(forEntryID: DemoCatalog.customEntryID) == .modelNotReady
            {
                showModelPicker = true
            }
            recentDetectors.addOrPromote(id: imageSelectedDetectorID)
            selectImageDetector()
        }
    }

    /// Pick `url`: acquire scope, register in the MRU, decode to an upright
    /// `Frame`, run detection once, then release the PRIOR scope strictly after
    /// `setImage` returns (the sandbox-scope ordering contract). Mirrors the
    /// playback `swapToExternal` scope ordering.
    @MainActor
    private func pickImage(url: URL) {
        guard let entry = imageResolvedEntry else { return }

        guard url.startAccessingSecurityScopedResource() else {
            let message = "Could not access \(url.lastPathComponent) (security scope denied)."
            Logger.demo.error(
                "startAccessingSecurityScopedResource failed for \(url.path, privacy: .public)"
            )
            imageErrorText = message
            return
        }

        withAnimation(.snappy) {
            recentImages.addOrPromote(url)
        }

        let frame: Frame
        do {
            frame = try ImageFrameDecoder().frame(fromImageAt: url)
        } catch {
            url.stopAccessingSecurityScopedResource()
            let message = "Could not decode \(url.lastPathComponent): \(error)"
            Logger.demo.error("\(message, privacy: .public)")
            imageErrorText = message
            return
        }

        let priorScopedURL = imageScopedURL
        imageScopedURL = url
        imageErrorText = nil

        Task { @MainActor in
            await imageCoordinator.setImage(frame, detector: entry)
            if let priorScopedURL {
                priorScopedURL.stopAccessingSecurityScopedResource()
            }
        }
    }

    /// Re-run detection on the held image under the newly-selected detector.
    @MainActor
    private func selectImageDetector() {
        guard let entry = imageResolvedEntry else { return }
        Task { @MainActor in
            await imageCoordinator.selectDetector(entry)
        }
    }
}

extension Logger {
    fileprivate static let demo = Logger(subsystem: "iris.demo", category: "phase5")
}
