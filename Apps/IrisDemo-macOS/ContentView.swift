@preconcurrency import AVFoundation
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
/// `videoRect` for the `DetectionLayer` is read from `playerLayer.videoRect`
/// every TimelineView tick — that's the on-screen rect the video occupies
/// after `.resizeAspect` letterbox/pillarbox, which `PlayerLayerConverter`
/// needs as input. `PlaybackSession.videoRect: AsyncStream<CGRect>` is the
/// eventual reactive plumbing per M3.md §Phase 3; for the smoke demo, the
/// per-tick read is simpler and equivalent.
struct ContentView: View {
    @State private var controller: PlaybackController?
    @State private var resultStore = ResultStore()
    @State private var converter = PlayerLayerConverter()
    @State private var playerLayer: AVPlayerLayer?
    @State private var detectionTask: Task<Void, Never>?
    @State private var showFilePicker = false
    @State private var errorText: String?

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
    private let catalog = DetectorCatalog.builtInVision
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
            // M5·P5: one scrolling pane, three regions separated by rules —
            // the filter controls (Detector picker + Tuning) lead at the
            // TOP; Live detections takes the generous middle (it's the
            // focus); Metrics anchors the BOTTOM. `Divider()`s mark the
            // region boundaries and the wider `spacing` keeps it from
            // reading as jammed-together. The detector picker is always
            // visible (even on an empty workspace); tuning is the active
            // session's capability-derived `settingsView`; Live detections
            // is the `DetectionInspector` reading the SAME
            // `resultStore.lookup` the overlay reads, as a render/cache
            // diagnostic; Metrics is the verbose `DetectionMetricsView`.
            // The gear button stays toggleable.
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // 1. Detector — always-visible picker. Changing the
                    //    selection rebuilds `session` + restarts the loop
                    //    (see `.onChange(of: selectedDetectorID)`).
                    inspectorSection("Detector") {
                        Picker("Detector", selection: $selectedDetectorID) {
                            ForEach(catalog.entries) { entry in
                                Text(entry.displayName).tag(entry.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityLabel("Active detector")
                    }

                    // 2. Tuning — the session's capability-derived settings.
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

                    // 3. Live detections — same lookup the overlay reads.
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

                    // 4. Metrics — verbose, counts-lead gauge.
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
            // M5·P4 follow-up: the detector picker moved INTO the inspector
            // (at the top of the pane); only the gear "Tune" toggle remains
            // in the toolbar as the entry point.
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
            swapDetector()
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

    /// The `PlaybackView` + `DetectionLayer` stack. The overlay is conditional
    /// on `playerLayer` because `PlayerLayerConverter` needs the AVF layer to
    /// compute `videoRect` — the layer is wired in via `PlaybackView`'s
    /// `onPlayerLayerReady` callback, which fires the first time the view
    /// is built.
    @ViewBuilder
    private func playbackArea(controller: PlaybackController) -> some View {
        ZStack {
            PlaybackView(source: controller.source) { layer in
                // `onPlayerLayerReady` fires inside `makeNSView`. Deferring
                // the `@State` write one runloop tick avoids SwiftUI's
                // "modifying state during view update" warning.
                Task { @MainActor in
                    self.converter = PlayerLayerConverter(playerLayer: layer)
                    self.playerLayer = layer
                }
            }

            if let playerLayer {
                // Outer TimelineView samples `playerLayer.videoRect` at the
                // same ~60 Hz cadence as the overlay's own TimelineView, so
                // window resizes / aspect changes propagate without manual
                // KVO. The overlay still owns its draw-time tick internally.
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
                    DetectionLayer(
                        store: resultStore,
                        converter: converter,
                        videoRect: playerLayer.videoRect,
                        stalenessThreshold: resultStore.playbackStalenessThreshold,
                        tuning: session?.router,
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
        // FIX 1: do NOT null `playerLayer` (nor reset `converter`). On a
        // source swap the SwiftUI view identity is unchanged, so only
        // `updateNSView` runs — it reuses the same `AVPlayerLayer` and just
        // re-points its `.player`. `onPlayerLayerReady` (which writes
        // `playerLayer`) fires only from `makeNSView`, so nulling here
        // leaves `playerLayer` nil forever after the first swap and the
        // overlay branch never re-mounts. The existing layer/converter
        // remain valid across the swap.

        // M5·P4: build the active detector session from the catalog and
        // spin up the detection loop bound to its router. The demo holds
        // only the type-erased `ActiveDetectorSession` — no concrete
        // detector or tuning view is named here.
        buildSessionAndStartDetection(on: newController)

        // Kick off playback through the controller so its state mirror
        // refreshes alongside the source. From `.idle`, `togglePlay()`
        // transitions to `.running`; the controller surfaces AVF errors
        // via the periodic time observer (logged to `iris.playback`).
        newController.togglePlay()
    }

    /// M5·P4: build the catalog session for `selectedDetectorID`, wire its
    /// pause-emit hook to `controller`, and (re)start the detection loop
    /// bound to the session's router. Shared by initial session start and
    /// detector-swap. Cancels any running loop before starting a new one.
    @MainActor
    private func buildSessionAndStartDetection(on controller: PlaybackController) {
        detectionTask?.cancel()
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
        buildSessionAndStartDetection(on: controller)
        // Re-emit the visible frame so a paused player still re-runs
        // detection under the freshly-selected detector. Same primitive as
        // the `.detector`-tier pause-emit hook.
        let target = controller.currentTime
        let source = controller.source
        Task { try? await source.seek(to: target) }
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
        playerLayer = nil
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
