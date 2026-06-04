#if os(macOS)
import AppKit
#endif
import Iris
import SwiftUI
import UniformTypeIdentifiers
import os

/// The unified cross-platform demo shell (M9·P3): ONE `NavigationSplitView`
/// holding ALL coordinators (playback + image, plus iOS capture state) for the
/// shell's lifetime, a single shared `ModelSelection`, the MRUs / model-store /
/// flagging / export state, and an active-`page` enum routing the detail pane.
///
/// **Why one shell holds everything.** Replacing the iOS `TabView` + the macOS
/// `Videos | Images` segmented picker with one long-lived shell removes the
/// per-page disappear/reload (A4) and the sidebar scroll-reset (A7): the
/// coordinators and the sidebar/RECENT list persist; only sidebar row expansion
/// and detail routing change as `page` flips.
///
/// **Coordinator lifecycle.** All coordinators persist. The playback detect
/// loop may keep running while another page is active (matches the macOS model
/// this shell adopts — simplest). **Capture is the exception:** its camera
/// start / `invalidate()` is driven off the active-page selection
/// (`.onChange(of: page)`), NOT view `.onDisappear`, preserving the documented
/// AVFoundation safety (the `videoDeviceNotAvailableInBackground` / double-
/// session race the prior `CaptureContentView` guarded against).
struct IrisShell: View {
    // MARK: - Shared state (one instance for the whole app)

    /// The single app-level model selection — one detector + one min-confidence
    /// floor shared across Playback, Image, and Capture (M9·P2/P3).
    @State var modelSelection = ModelSelection()

    /// Owns the playback detection-session orchestration (detect loop,
    /// `ResultStore` + metrics, `PlaybackController`, `ActiveDetectorSession`).
    @State var coordinator = PlaybackDetectionCoordinator()

    /// One-shot image detection orchestration: a held still `Frame`, the
    /// `ResultStore` + metrics, and the `ActiveDetectorSession`.
    @State var imageCoordinator = ImageDetectionCoordinator()

    /// Bundled-model warm-up cache + the file-picked detector.
    @State var modelStore = DemoModelStore()

    /// MRUs (UserDefaults-backed; persist across launches).
    @State var recentVideos = RecentVideos()
    @State var recentImages = RecentImages()
    @State var recentDetectors = RecentDetectors()

    // M7: flagging + export (shared FlagStore between writer + reader).
    @State var flaggingModel: FlaggingModel?
    @State var flagStore: FlagStore?
    @State var exportCoordinator: FrameExportCoordinator?

    @Environment(\.scenePhase) var scenePhase
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    // MARK: - Navigation

    /// The active page — routes the sidebar's active-row expansion and the
    /// detail pane. Defaults to Playback.
    @State var page: ShellPage = .playback

    /// Sidebar column visibility — drives the persistent split at regular width
    /// (iPad / Mac). SwiftUI ignores this once the split *collapses* to a single
    /// column at compact width — see `preferredCompactColumn`.
    @State var columnVisibility: NavigationSplitViewVisibility = .all

    /// Which column the *collapsed* (compact-width iPhone) split shows. This —
    /// not `columnVisibility` — is the only navigation lever once collapsed.
    /// Defaults to `.detail` so we land on the active page's content (the video
    /// player), not the sidebar; the toolbar drawer button flips it to
    /// `.sidebar`, and picking a page snaps it back to `.detail`.
    @State var preferredCompactColumn: NavigationSplitViewColumn = .detail

    // MARK: - Playback chrome state

    @State var scopedURL: URL?
    @State var activeLabel: String = ""
    @State var errorText: String?
    @State var showTuning = false
    /// The detector id last installed into the playback coordinator (drift guard).
    @State var syncedVideoDetectorID: String?

    /// The single file-importer state for the whole shell. One enum-routed
    /// importer per platform presents off this and dispatches by case (M9·P5) —
    /// replaces the prior five per-platform `show*Picker` / `activeImporter`
    /// flags.
    @State var importTarget: ImportTarget?

    // MARK: - Image chrome state

    @State var imageScopedURL: URL?
    @State var imageErrorText: String?
    @State var showImageTuning = false
    @State var syncedImageDetectorID: String?

    // MARK: - Dataset count (read-only display in the reserved strip)

    @State var exportedFrameCount: Int?

    // MARK: - Capture state (iOS only; lifecycle keyed to `page`)

    #if os(iOS)
    @State var capture = CaptureModel()
    #endif

    // MARK: - Inspector presentation (compact bottom-sheet at compact width)

    @State var showInspectorSheet = false

    // MARK: - Derived

    var catalog: DetectorCatalog { DemoCatalog.detectors(store: modelStore) }
    var selectedDetectorID: String { modelSelection.detectorID }

    var resolvedEntry: DetectorCatalogEntry? {
        catalog.entries.first(where: { $0.id == selectedDetectorID })
            ?? catalog.entries.first
    }

    /// Capture is only available where there's a camera. macOS has none; on iOS
    /// the simulator / Mac-Designed-for-iPad also lack one.
    var captureAvailable: Bool {
        #if os(iOS)
        return CaptureModel.cameraAvailable
        #else
        return false
        #endif
    }

    /// Whether the layout is at regular width (docked inspector) vs. compact
    /// (bottom-sheet inspector). macOS is always regular.
    var isRegularWidth: Bool {
        #if os(macOS)
        return true
        #else
        return horizontalSizeClass == .regular
        #endif
    }

    /// Reveal-in-Finder intent for the DATASET strip — macOS-only (`nil` on iOS,
    /// which has no Finder and never carried this footer).
    private var revealInFinderAction: (() -> Void)? {
        #if os(macOS)
        return { revealFramesInFinder() }
        #else
        return nil
        #endif
    }

    private var exportedFrameCountText: String {
        switch exportedFrameCount {
        case .none, .some(0): return "No frames yet"
        case .some(1): return "1 exported"
        case .some(let n): return "\(n) exported"
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            SidebarView(
                page: $page,
                catalog: catalog,
                recentDetectors: recentDetectors,
                modelStore: modelStore,
                modelSelection: modelSelection,
                selectedDetectorID: selectedDetectorID,
                captureAvailable: captureAvailable,
                recentVideos: recentVideos.resolve(),
                onOpenVideo: presentVideoPicker,
                onPickVideo: { swapToExternal(url: $0) },
                recentImages: recentImages.resolve(),
                onOpenImage: presentImagePicker,
                onPickImage: { pickImage(url: $0) },
                exportedFrameCountText: exportedFrameCountText,
                isSweeping: exportCoordinator?.isSweeping ?? false,
                lastSummaryText: exportCoordinator?.lastSummary?.demoStatusLine,
                onExportNow: exportCoordinator == nil ? nil : {
                    await exportCoordinator?.exportNow()
                    refreshExportedFrameCount()
                },
                onRevealInFinder: revealInFinderAction
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .fileImporting(self)
        } detail: {
            // The app toolbar is attached HERE, on the detail content (not the
            // split-view container), so `.primaryAction` items render on the
            // DETAIL toolbar's trailing edge (top-right, adjacent to the right
            // inspector) on macOS instead of clustering over the left pane. The
            // system sidebar toggle stays leading; the iOS compact drawer toggle
            // (`.topBarLeading`) and sheet path are unaffected.
            detailPane
                .toolbar { detailToolbar }
        }
        #if os(macOS)
        .frame(minWidth: 880, minHeight: 480)
        #endif
        .inspectorPresentation(self)
        .onChange(of: selectedDetectorID) { onDetectorChanged() }
        .onChange(of: page) { _, newPage in onPageChanged(to: newPage) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive: exportCoordinator?.triggerSweep()
            case .active: exportCoordinator?.cancelInFlight()
            @unknown default: break
            }
        }
        .task { await bootstrap() }
        .environment(modelSelection)
    }

    // MARK: - Detail routing

    @ViewBuilder
    private var detailPane: some View {
        switch page {
        case .playback:
            playbackDetail
        case .image:
            imageDetail
        case .capture:
            captureDetail
        }
    }

    // MARK: - Bootstrap

    @MainActor
    private func bootstrap() async {
        if flaggingModel == nil {
            let documents = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first!
            let store = FlagStore(baseDir: documents)
            flagStore = store
            flaggingModel = FlaggingModel(store: store, source: coordinator)
            exportCoordinator = FrameExportCoordinator(
                store: store,
                baseDir: documents,
                recentVideos: recentVideos
            )
            // Launch selection is the shared, persisted `ModelSelection`. If its
            // id is stale (not in this catalog), fall back to the first entry.
            if catalog.entries.first(where: { $0.id == selectedDetectorID }) == nil,
                let first = catalog.entries.first
            {
                modelSelection.detectorID = first.id
            }
            refreshExportedFrameCount()
            #if os(iOS)
            // iOS first-launch: auto-load the bundled fixture so Playback has
            // something to show without a picker (matches the prior TabView).
            if coordinator.controller == nil {
                loadFixture()
            }
            #endif
        }
        await modelStore.prewarmBundledModels()
    }

    // MARK: - Change handlers

    @MainActor
    private func onDetectorChanged() {
        if selectedDetectorID == DemoCatalog.customEntryID,
            modelStore.availability(forEntryID: DemoCatalog.customEntryID) == .modelNotReady
        {
            importTarget = .model
        }
        recentDetectors.addOrPromote(id: selectedDetectorID)
        // One shared selection drives BOTH coordinators; each no-ops if its
        // coordinator has nothing loaded.
        swapDetector()
        selectImageDetector()
        #if os(iOS)
        capture.updateDetector(for: resolvedEntry)
        #endif
    }

    @MainActor
    private func onPageChanged(to newPage: ShellPage) {
        // On a collapsed (compact iPhone) split, picking a page in the drawer
        // should navigate to that page's detail. No-op when not collapsed.
        preferredCompactColumn = .detail
        #if os(iOS)
        // Capture lifecycle keys off the active-page selection (NOT view
        // .onDisappear), preserving the documented AVFoundation safety. Start
        // when arriving on Capture; tear down when leaving it.
        if newPage == .capture {
            capture.start(
                initialEntry: resolvedEntry,
                minConfidence: { Float(modelSelection.minConfidence) }
            )
        } else {
            capture.teardown()
        }
        #endif
    }

    // MARK: - Inspector content (shared by docked + sheet presentations)

    /// `LIVE DETECTIONS` + `METRICS` (+ Tuning + Flagged frames on the playback
    /// page) for the active page's coordinator. Hosted docked at regular width
    /// (`.inspector`) and in a bottom sheet at compact width.
    @ViewBuilder
    var inspectorContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let modelError = modelStore.pickedModelError {
                    Text(modelError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // One unified Tuning panel split into two delineated groups
                // (`TuningGroups`): a **Detector** group (name + input knobs,
                // confidence suppressed) and a **Display** group (the global
                // "Min confidence" floor + per-class tri-state rows). Rendered
                // when EITHER a session OR present labels exist — Capture has no
                // session but still surfaces the Display group. Gated out
                // entirely when both are absent so there's no empty "Tuning" box.
                if activeSession != nil || !presentLabels.isEmpty {
                    // No "Tuning" section title (redesign): the panel leads with
                    // the prominent detector-name callout itself.
                    TuningGroups(
                        detectorName: resolvedEntry?.displayName,
                        settingsView: activeSession?.settingsView,
                        modelSelection: modelSelection,
                        presentLabels: presentLabels,
                        availableLabels: resolvedEntry?.availableLabels
                    )

                    Divider()
                }

                inspectorSection("Live detections") {
                    liveDetectionsInspector
                }
                .frame(minHeight: 240, alignment: .top)

                Divider()

                inspectorSection("Metrics") {
                    DetectionMetricsView(metrics: activeMetrics)
                }

                if page == .playback {
                    Divider()
                    inspectorSection("Flagged frames") {
                        if let flaggingModel {
                            FlaggedFramesList(model: flaggingModel)
                                .frame(minHeight: 160)
                        } else {
                            Text("Open a video to flag frames.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The active mode's `ResultStore` — the one feeding the visible overlay,
    /// chosen by `page` (M10·P3). The sidebar's per-class controls read present
    /// labels off this; because `ResultStore` is `@Observable`, deriving labels
    /// from it in the sidebar body updates the rows as detections arrive.
    var activeResultStore: ResultStore? {
        switch page {
        case .playback: return coordinator.resultStore
        case .image: return imageCoordinator.resultStore
        #if os(iOS)
        case .capture: return capture.resultStore
        #else
        case .capture: return nil
        #endif
        }
    }

    /// The distinct, non-empty `Detection.label`s currently visible in the active
    /// mode's store — the present-only roster the inspector's per-class Tuning
    /// rows show (M10·P3/P4). Sourced via the SAME nearest-neighbor `lookup(at:)` shape the
    /// overlay + inspector use (matching `displayTimeSource` + staleness per
    /// page), so the labels track exactly what's drawn. The empty-string label
    /// (class-agnostic detectors like Vision rectangles stamp `""`) is filtered
    /// out — no per-class row for those. Reading `lookup` here observes the
    /// `@Observable` store, so this recomputes as detections change.
    var presentLabels: Set<String> {
        guard let store = activeResultStore else { return [] }
        let detections: [Detection]
        switch page {
        case .playback:
            guard let controller = coordinator.controller else { return [] }
            let time = MainActor.assumeIsolated { controller.currentTime }
            detections = store.lookup(at: time, stale: store.playbackStalenessThreshold)
        case .image:
            guard let frame = imageCoordinator.frame else { return [] }
            detections = store.lookup(at: frame.timestamp, stale: store.playbackStalenessThreshold)
        case .capture:
            detections = store.lookup(at: .zero, stale: store.liveStalenessThreshold)
        }
        return Set(detections.map(\.label).filter { !$0.isEmpty })
    }

    /// The active page's session (playback / image; capture has none).
    private var activeSession: ActiveDetectorSession? {
        switch page {
        case .playback: return coordinator.session
        case .image: return imageCoordinator.session
        case .capture: return nil
        }
    }

    private var activeMetrics: DetectionMetrics {
        switch page {
        case .playback: return coordinator.metrics
        case .image: return imageCoordinator.metrics
        #if os(iOS)
        case .capture: return capture.metrics
        #else
        case .capture: return coordinator.metrics
        #endif
        }
    }

    @ViewBuilder
    private var liveDetectionsInspector: some View {
        switch page {
        case .playback:
            if let controller = coordinator.controller {
                DetectionInspector(
                    store: coordinator.resultStore,
                    displayTimeSource: { [controller] in
                        MainActor.assumeIsolated { controller.currentTime }
                    },
                    stalenessThreshold: coordinator.resultStore.playbackStalenessThreshold
                )
            } else {
                Text("Open a video to inspect detections.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .image:
            if imageCoordinator.frame != nil {
                DetectionInspector(
                    store: imageCoordinator.resultStore,
                    displayTimeSource: { [imageCoordinator] in
                        MainActor.assumeIsolated { imageCoordinator.frame?.timestamp ?? .zero }
                    },
                    stalenessThreshold: imageCoordinator.resultStore.playbackStalenessThreshold
                )
            } else {
                Text("Pick an image to inspect detections.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .capture:
            #if os(iOS)
            DetectionInspector(
                store: capture.resultStore,
                displayTimeSource: { .zero },
                stalenessThreshold: capture.resultStore.playbackStalenessThreshold
            )
            #else
            EmptyView()
            #endif
        }
    }

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

    // MARK: - Toolbar (bookmark + tune, top-right of the detail)

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        #if os(iOS)
        // Compact (iPhone): an explicit sidebar drawer toggle, top-left. At
        // regular width NavigationSplitView already shows its own column
        // control, so the explicit toggle is compact-only.
        ToolbarItem(placement: .topBarLeading) {
            if !isRegularWidth {
                Button {
                    withAnimation {
                        // Compact split is collapsed: navigate between the
                        // sidebar drawer and the detail via the compact column,
                        // NOT `columnVisibility` (ignored when collapsed).
                        preferredCompactColumn =
                            preferredCompactColumn == .sidebar ? .detail : .sidebar
                    }
                } label: {
                    Label("Toggle sidebar", systemImage: "sidebar.leading")
                }
                .accessibilityLabel("Toggle sidebar")
            }
        }
        #endif

        // ONE trailing cluster in the main window toolbar, ordered left→right
        // [Freeze (frame)][Flag (bookmark)][Tune (panel)] — user call, locked:
        // all three live HERE, in this order, never split across a second
        // detail-scoped toolbar (splitting let macOS regroup them
        // unpredictably). Freeze + Flag are playback-page-only.

        // Freeze this frame onto the Image page. Fires the freeze-from-live
        // hand-off (`inspectFrame`) against the live `currentFrame`; disabled
        // when there's no frame to freeze.
        ToolbarItem(placement: .primaryAction) {
            if page == .playback {
                Button {
                    inspectFrame(coordinator.currentFrame)
                } label: {
                    Label("Freeze frame", systemImage: "camera.viewfinder")
                }
                .disabled(coordinator.currentFrame == nil)
                .help("Freeze this frame on the Image page")
                .accessibilityLabel("Freeze frame")
            }
        }

        // Flag / unflag the current playback frame. Shown once a flagging
        // asset is loaded.
        ToolbarItem(placement: .primaryAction) {
            if page == .playback, let flaggingModel, flaggingModel.asset != nil {
                Button {
                    flaggingModel.toggleCurrent()
                } label: {
                    Label(
                        "Flag frame",
                        systemImage: flaggingModel.isCurrentFlagged() ? "bookmark.fill" : "bookmark"
                    )
                }
                .help("Flag / unflag the current frame")
                .accessibilityLabel("Flag frame")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                if isRegularWidth {
                    showTuning.toggle()
                } else {
                    showInspectorSheet.toggle()
                }
            } label: {
                Label("Tune", systemImage: "slider.horizontal.3")
            }
            .help("Toggle the inspector")
        }
    }

    // MARK: - Inspector presentation accessors (used by the modifier)

    var inspectorDockedBinding: Binding<Bool> { $showTuning }
    var inspectorSheetBinding: Binding<Bool> { $showInspectorSheet }

    // MARK: - Importer accessors (cross the `private @State` boundary for the
    // presentation extension)

    var importTargetValue: ImportTarget? { importTarget }
    func clearImportTarget() { importTarget = nil }
}

extension Logger {
    static let shell = Logger(subsystem: "iris.demo", category: "shell")
}
