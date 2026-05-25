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

    /// M4 Phase 3: live tuning model for the active Vision rectangle
    /// detector. One instance per `ContentView`; `swapToExternal`
    /// rebuilds it alongside the detector so the model's settings
    /// reflect the fresh detector. The `.inspector`-hosted
    /// `VisionRectanglesTuningView` binds to this; writes route
    /// through `model.binding(_:)` → `update(_:to:)` → tier classifier
    /// → cache invalidation on `.detector` tiers.
    @State private var tuningModel: TuningModel<VisionRectanglesDetector>?

    /// Whether the inspector panel is showing. Gear-icon toolbar
    /// toggle flips this; the inspector hosts the live
    /// `VisionRectanglesTuningView` over `tuningModel`.
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
            // M4 Phase 3: live tuning inspector. Hosts
            // `VisionRectanglesTuningView` over the active session's
            // `tuningModel`. Empty state shows when no session is
            // loaded — gear button stays toggleable so users learn
            // where the panel lives even on an empty workspace.
            Group {
                if let tuningModel {
                    VisionRectanglesTuningView(model: tuningModel)
                } else {
                    ContentUnavailableView(
                        "No session",
                        systemImage: "slider.horizontal.3",
                        description: Text("Open a video to start tuning.")
                    )
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showTuning.toggle()
                } label: {
                    Label("Tune", systemImage: "slider.horizontal.3")
                }
                .help("Toggle tuning inspector")
                .disabled(tuningModel == nil)
            }
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
                let selectionBinding = Binding<URL?>(
                    get: { scopedURL },
                    set: { newValue in
                        if let url = newValue, url != scopedURL {
                            swapToExternal(url: url)
                        }
                    }
                )
                List(selection: selectionBinding) {
                    ForEach(recents, id: \.self) { url in
                        recentRow(url: url)
                            .tag(url)
                    }
                }
                .listStyle(.sidebar)
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
                        tuning: tuningModel,
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
        recentVideos.addOrPromote(url)

        let source = PlaybackSource(url: url)
        let newController = PlaybackController(source: source)
        let initialDetector = VisionRectanglesDetector(
            minimumAspectRatio: 0.3,
            maximumAspectRatio: 1.0,
            minimumSize: 0.1,
            label: "rect"
        )
        let pipeline = DetectorPipeline(initialDetector)

        // M4 Phase 3: bind the live tuning model to the same detector
        // the pipeline runs through. `cache: resultStore` means
        // `.detector`-tier knob changes invalidate the playback cache
        // so the next decode produces fresh detections under the new
        // settings. The model is passed as the `tuning:` argument to
        // `detect(in:cache:tuning:)` below.
        let newTuning = TuningModel(detector: initialDetector, cache: resultStore)

        // M4 polish: pause-emit hook. A `.detector`-tier change clears
        // the cache; if the source is paused, no frames flow → cache
        // stays empty → overlay reads nil → detections disappear
        // mid-tuning. Seeking to the current time re-emits a one-shot
        // frame through `PlaybackSource.emitOneShotFrame()` (the same
        // primitive M3 Phase 2 uses for `seek` / `step`), giving the
        // pipeline a frame to re-run under the new detector.
        newTuning.onDetectorTierChange = { [weak newController] in
            guard let controller = newController else { return }
            let source = controller.source
            let target = controller.currentTime
            Task { try? await source.seek(to: target) }
        }

        // Spawn the detector loop. Per the runtime decisions doc the
        // `for await` loop owns task lifetime — we cancel by canceling
        // the wrapping Task. The pipeline owns cache write-through on
        // miss (playback-detection-cache Phase 2); cache hits on
        // revisited timestamps skip the detector dispatch entirely so
        // backward seeks into already-played regions paint instantly.
        let store = resultStore
        let task = Task { [tuning = newTuning] in
            for await frame in source.frames {
                if Task.isCancelled { break }
                do {
                    _ = try await pipeline.detect(in: frame, cache: store, tuning: tuning)
                } catch {
                    Logger.demo.error(
                        "detect failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }

        self.scopedURL = url
        self.activeLabel = url.lastPathComponent
        self.controller = newController
        self.detectionTask = task
        self.tuningModel = newTuning
        self.errorText = nil
        self.playerLayer = nil  // re-bound when PlaybackView attaches

        // Kick off playback through the controller so its state mirror
        // refreshes alongside the source. From `.idle`, `togglePlay()`
        // transitions to `.running`; the controller surfaces AVF errors
        // via the periodic time observer (logged to `iris.playback`).
        newController.togglePlay()
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

        // Clear the pause-emit hook before dropping the model reference
        // — defensive: the closure captures `newController` weakly, but
        // dropping the slot eliminates any chance of a stale fire
        // crossing the swap boundary.
        tuningModel?.onDetectorTierChange = nil

        controller = nil
        playerLayer = nil
        scopedURL = nil
        activeLabel = ""
        tuningModel = nil
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
