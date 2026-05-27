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
/// Lifecycle:
/// - `Open Video…` button presents an `NSOpenPanel`-backed `.fileImporter`
///   for `.movie` URLs. Sidebar rows for previously-picked clips re-open
///   them without the panel.
/// - On pick OR sidebar tap: `swapToExternal(url:)` tears down the prior
///   session (releasing any prior security scope), acquires a fresh scope
///   for the new URL, registers in `RecentVideos`, builds a
///   `PlaybackController(source: PlaybackSource(url:))`, kicks off a
///   detector task draining `controller.source.frames`, then
///   `controller.togglePlay()`.
/// - On view teardown: cancel the detector task, `source.invalidate()`, then
///   `stopAccessingSecurityScopedResource()`. That ordering keeps the
///   security scope alive while AVF still holds the URL.
///
/// **Security-scope accounting.** Every source swap (pick OR MRU tap) goes
/// through `swapToExternal(url:)`, which calls `teardown()` *first* to
/// release any prior scope before acquiring the new one. `scopedURL` holds
/// the URL currently under scope (nil when there is no active session) and
/// is the single source of truth `teardown()` reads when balancing
/// `stopAccessingSecurityScopedResource()`. Mirrors the iOS demo's Phase 2
/// pattern.
///
/// The `DetectionLayer`'s geometry is computed by `VideoGeometry` from the
/// controller's `presentationSize` (the upright displayed video size) and
/// the SwiftUI-measured container size — no `AVPlayerLayer.videoRect` read.
/// Player + overlay share one `.resizeAspect` (centered aspect-fit) frame,
/// so `VideoGeometry.displayRect` lands on the on-screen video; window
/// resizes propagate through the overlay's `GeometryReader` automatically.
struct ContentView: View {
    @State private var controller: PlaybackController?
    @State private var resultStore = ResultStore()
    @State private var detectionTask: Task<Void, Never>?
    @State private var showFilePicker = false
    @State private var errorText: String?

    /// M6·P3: holds the bundled-model warm-up cache + the file-picked detector.
    /// `@Observable` so the picker re-renders when the custom slot loads.
    @State private var modelStore = DemoModelStore()

    /// M6·P3: presents the Core ML model importer (`.mlpackage` / `.mlmodel`).
    @State private var showModelPicker = false

    /// Best-effort pipeline gauge. `@MainActor @Observable` — surfaced in
    /// the bottom bar (avg inference ms · effective det/s · drop %). Reset
    /// per video / detector swap.
    @State private var metrics = DetectionMetrics()

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

    /// Display-only: human-readable label of the active source. The URL's
    /// last path component when one is loaded; empty otherwise.
    @State private var activeLabel: String = ""

    /// M5·P4: the general detector-selection layer. `catalog` lists the
    /// selectable detectors (built-in Vision rectangles + body pose);
    /// `selectedDetectorID` is the toolbar picker binding; `session` is the
    /// type-erased active detector + its capability-derived settings view,
    /// rebuilt by `swapToExternal` and on every picker change. The demo
    /// never names a concrete detector or tuning view in the playback path
    /// — it goes through the catalog. Rectangles is the default so pre-M5
    /// behavior is preserved until the user picks Body Pose.
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
    @State private var session: ActiveDetectorSession?

    /// Whether the inspector panel is showing. Gear-icon toolbar toggle
    /// flips this; the inspector hosts the active session's
    /// capability-derived `settingsView`.
    @State private var showTuning = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detailArea
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
                        if let session {
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
                        if let controller {
                            DetectionInspector(
                                store: resultStore,
                                displayTimeSource: { [controller] in
                                    controller.currentTime
                                },
                                stalenessThreshold: resultStore.playbackStalenessThreshold
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
                        DetectionMetricsView(metrics: metrics)
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
                    ForEach(catalog.entries) { entry in
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
            swapDetector()
        }
        // M6·P3: warm the bundled Core ML models off the main actor at launch
        // so the first selection isn't a cold compile/load stall. Idempotent.
        .task {
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
        // unhooked. SwiftUI calls `onDisappear` on window close.
        .onDisappear {
            teardown()
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
            HStack {
                Text("Recent videos")
                    .font(.headline)
                Spacer()
                Button {
                    showFilePicker = true
                } label: {
                    Label("Open", systemImage: "folder.badge.plus")
                        .labelStyle(.iconOnly)
                }
                .help("Open Video…")
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
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
        }
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
                Text(url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// Right-hand detail pane. Shows the player + scrubber + bottom bar
    /// when a session is active; otherwise the empty state with a CTA.
    @ViewBuilder
    private var detailArea: some View {
        VStack(spacing: 0) {
            if let controller {
                playbackArea(controller: controller)

                Scrubber(model: controller)
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
                store: resultStore,
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
                stalenessThreshold: resultStore.playbackStalenessThreshold,
                tuning: session?.router,
                displayTimeSource: { [controller] in
                    // Same MainActor draw-time guarantee as `makeConverter`.
                    MainActor.assumeIsolated { controller.currentTime }
                }
            )
            .allowsHitTesting(false)
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
                Text(metrics.compactSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("Open Video…") { showFilePicker = true }
                .controlSize(.small)
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
    /// Order matters: tear down the prior session FIRST (which releases any
    /// prior `scopedURL`), THEN acquire the new security scope and build
    /// the new controller. Reversing the order would double-scope or leak
    /// the prior scope across the swap.
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
        // Wrap the model mutation in an animation transaction so the List
        // row animates its move to the top (the ForEach is keyed by stable
        // URL id, so SwiftUI can interpolate the reorder).
        withAnimation(.snappy) {
            recentVideos.addOrPromote(url)
        }

        // Per-session counters reset on a new video.
        metrics.reset()

        let source = PlaybackSource(url: url)
        let newController = PlaybackController(source: source)

        self.scopedURL = url
        self.highlightedURL = url
        self.activeLabel = url.lastPathComponent
        self.controller = newController
        self.errorText = nil
        // The overlay now keys off `controller.presentationSize` (an
        // `@Observable` on the new controller) and the SwiftUI-measured
        // frame — no `AVPlayerLayer` handle to thread across the swap.

        // M5·P4: build the active detector session from the catalog and
        // spin up the detection loop bound to its router. The demo holds
        // only the type-erased `ActiveDetectorSession` — no concrete
        // detector or tuning view is named here. The build is now async (it
        // drains any prior single-consumer stream loop before starting a new
        // one), so it runs in a `@MainActor` Task; playback starts after the
        // new consumer is in place.
        Task { @MainActor in
            await buildSessionAndStartDetection(on: newController)

            // Kick off playback through the controller so its state mirror
            // refreshes alongside the source. From `.idle`, `togglePlay()`
            // transitions to `.running`; the controller surfaces AVF errors
            // via the periodic time observer (logged to `iris.playback`).
            newController.togglePlay()
        }
    }

    /// M5·P4: build the catalog session for `selectedDetectorID`, wire its
    /// pause-emit hook to `controller`, and (re)start the detection loop
    /// bound to the session's router. Shared by initial session start and
    /// detector-swap. Cancels any running loop before starting a new one.
    @MainActor
    private func buildSessionAndStartDetection(on controller: PlaybackController) async {
        detectionTask?.cancel()
        // `PlaybackSource.frames` is a single-consumer `AsyncStream`. Cancellation
        // is cooperative, so the old `for await` loop may still be draining when we
        // get here. Awaiting the task's value blocks until that loop fully exits, so
        // the new consumer below is the *only* consumer before we re-emit the seek
        // frame — otherwise that one re-emitted frame races between two live
        // consumers and the old (stale) detector can win. `AsyncStream`'s iterator
        // is cancellation-aware, so this returns promptly.
        await detectionTask?.value
        session?.router.onDetectorTierChange = nil

        guard
            let entry = catalog.entries.first(where: { $0.id == selectedDetectorID })
                ?? catalog.entries.first
        else { return }

        // `cache: resultStore` (passed into `makeSession`) means
        // `.detector`-tier knob changes invalidate the playback cache so
        // the next decode produces fresh detections under the new settings.
        let newSession = entry.makeSession(resultStore)

        // M4 polish: pause-emit hook. A `.detector`-tier change clears the
        // cache; if the source is paused, no frames flow → overlay reads
        // nil → detections disappear mid-tuning. Seeking to the current
        // time re-emits a one-shot frame (the same primitive M3 Phase 2
        // uses for `seek` / `step`), giving the pipeline a frame to re-run
        // under the new detector.
        newSession.router.onDetectorTierChange = { [weak controller] in
            guard let controller else { return }
            let source = controller.source
            let target = controller.currentTime
            Task { try? await source.seek(to: target) }
        }

        // Spawn the detector loop. Per the runtime decisions doc the
        // `for await` loop owns task lifetime — we cancel by canceling the
        // wrapping Task. The pipeline owns cache write-through on miss
        // (playback-detection-cache Phase 2); cache hits on revisited
        // timestamps skip the detector dispatch entirely. The pipeline's
        // own detector array is empty — the router's `currentDetector`
        // (the catalog-built detector) is what actually runs, per the
        // `detect(in:cache:tuning:)` hot-swap contract.
        let store = resultStore
        let pipeline = DetectorPipeline([])
        let source = controller.source
        let metrics = self.metrics
        let task = Task { [router = newSession.router] in
            for await frame in source.frames {
                if Task.isCancelled { break }
                do {
                    // Time the inference and feed the best-effort gauge.
                    // `DetectionMetrics` is `@MainActor`, so record on the
                    // main actor; the cumulative source drop counter is
                    // bridged in alongside.
                    let clock = ContinuousClock()
                    let start = clock.now
                    _ = try await pipeline.detect(in: frame, cache: store, tuning: router)
                    let elapsed = clock.now - start
                    let seconds = Double(elapsed.components.seconds)
                        + Double(elapsed.components.attoseconds) / 1e18
                    let dropped = source.droppedFrameCount
                    let emitted = source.emittedFrameCount
                    await MainActor.run {
                        metrics.recordInference(seconds: seconds)
                        metrics.setDropped(dropped)
                        metrics.setEmitted(emitted)
                    }
                } catch {
                    Logger.demo.error(
                        "detect failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }

        self.session = newSession
        self.detectionTask = task
    }

    /// M5·P4: handle a picker selection change. Rebuilds the session for
    /// the newly-selected detector, invalidates the cache (old detections
    /// are from a different detector), restarts the detection loop bound to
    /// the new router, and re-emits the current frame so the new detector's
    /// output appears immediately even while paused.
    @MainActor
    private func swapDetector() {
        guard let controller else { return }
        resultStore.invalidateAll()
        // Per-session counters reset on a new detector.
        metrics.reset()
        // The build is async (it drains the prior single-consumer stream loop
        // before starting the new one), and the re-emit seek MUST happen after
        // that drain — otherwise the re-emitted frame races between the dying
        // old consumer and the new one. Sequencing both inside one `@MainActor`
        // Task preserves that ordering.
        Task { @MainActor in
            await buildSessionAndStartDetection(on: controller)
            // Re-emit the visible frame so a paused player still re-runs
            // detection under the freshly-selected detector. Same primitive as
            // the `.detector`-tier pause-emit hook.
            let target = controller.currentTime
            let source = controller.source
            try? await source.seek(to: target)
        }
    }

    /// Tear down the active playback session. Idempotent.
    ///
    /// Order: cancel detector → invalidate source → release security scope.
    /// Each step releases a hold on the file URL; reversing the order would
    /// briefly let AVF read from a URL whose security scope has already
    /// been dropped. `invalidate()` is `async`, so the security-scope release
    /// runs after it inside the same `Task` to preserve ordering.
    @MainActor
    private func teardown() {
        detectionTask?.cancel()
        detectionTask = nil

        let priorSource = controller?.source
        let priorScopedURL = scopedURL

        // Clear the pause-emit hook before dropping the session reference
        // — defensive: the closure captures `controller` weakly, but
        // dropping the slot eliminates any chance of a stale fire
        // crossing the swap boundary.
        session?.router.onDetectorTierChange = nil

        controller = nil
        scopedURL = nil
        highlightedURL = nil
        activeLabel = ""
        session = nil
        resultStore.clear()

        // Detach AVF observers + finish the frame stream, then release the
        // security scope. Capturing `priorSource` and `priorScopedURL`
        // locally means a follow-up `swapToExternal` can reset `@State` to
        // the new session synchronously while AVF tears the old one down
        // in the background.
        Task {
            if let priorSource {
                await priorSource.invalidate()
            }
            if let priorScopedURL {
                priorScopedURL.stopAccessingSecurityScopedResource()
            }
        }
    }
}

extension Logger {
    fileprivate static let demo = Logger(subsystem: "iris.demo", category: "phase5")
}
