import Iris
import SwiftUI
import UniformTypeIdentifiers
import os

/// Image tab (M8·P4): pick a still off-disk → decode to an upright `Frame` →
/// run the active detector once → draw the `DetectionLayer` overlay on the
/// displayed pixels. The static-image analogue of `PlaybackContentView`, minus
/// the scrubber / playback loop — it mounts the already-built
/// `ImageDetectionCoordinator` (one-shot detection on a held frame) and reuses
/// the shared `ImageDetailView` for the detail rendering.
///
/// **What this container owns (the outer layer).** File picking
/// (`DocumentPicker` configured for image types), security scope, the
/// `RecentImages` MRU, the detector catalog + custom-model warm-up, and the
/// pick → decode → `setImage` flow. The coordinator never touches disk: the
/// container decodes the picked URL via `ImageFrameDecoder` and hands the
/// `Frame` in — exactly as the playback page builds a `PlaybackSource`.
///
/// **Security-scope accounting** mirrors `PlaybackContentView.swapToExternal`:
/// acquire the new URL's scope before decoding, then release the PRIOR scope
/// strictly AFTER `coordinator.setImage` returns. `scopedURL` holds the
/// currently-scoped pick (nil before the first pick).
struct ImageContentView: View {
    /// One-shot image detection orchestration: a held still `Frame`, the
    /// `ResultStore` + `DetectionMetrics`, and the `ActiveDetectorSession`.
    @State private var coordinator = ImageDetectionCoordinator()

    /// MRU of recently-opened images. Persists across tab disappears via
    /// `UserDefaults`. The image-page sibling of `RecentVideos`.
    @State private var recentImages = RecentImages()

    /// MRU of recently-selected detectors (shared store with the playback page
    /// via its `UserDefaults` key) — drives the launch selection + picker order.
    @State private var recentDetectors = RecentDetectors()

    /// Bundled-model warm-up cache + the file-picked detector. `@Observable` so
    /// the picker re-renders when the custom slot loads.
    @State private var modelStore = DemoModelStore()

    private var catalog: DetectorCatalog { DemoCatalog.detectors(store: modelStore) }

    /// Resolve the current picker selection into a catalog entry, falling back
    /// to the first entry — the single point where a selection becomes the
    /// `DetectorCatalogEntry` handed to the coordinator.
    private var resolvedEntry: DetectorCatalogEntry? {
        catalog.entries.first(where: { $0.id == selectedDetectorID })
            ?? catalog.entries.first
    }

    /// M9·P2: the app-level shared model selection, injected at the root. The
    /// per-page `@State selectedDetectorID` is gone — the Image page now reads
    /// the SAME selection as Playback, so the two always run the same detector
    /// and the Image page no longer silently flips its detector on re-appear.
    @Environment(ModelSelection.self) private var modelSelection

    /// Read alias onto the shared selection's `detectorID`.
    private var selectedDetectorID: String { modelSelection.detectorID }

    /// M9·P2: the detector id last installed into this page's coordinator, so
    /// an on-appear sync can skip a redundant re-detect when the coordinator is
    /// already on the shared selection.
    @State private var syncedDetectorID: String?

    @State private var showTuning = false
    @State private var errorText: String?

    /// M8·P5: freeze-from-live conduit (injected at the root). A source page
    /// posts a frozen `Frame` + the live detector id here; this page consumes it
    /// — selects that detector, runs it on the still, then clears the request.
    @Environment(InspectorHandoff.self) private var handoff

    /// The file-picker sheet currently presented, if any. Routed through a single
    /// `.sheet(item:)` rather than two `.sheet(isPresented:)` modifiers: SwiftUI
    /// honors only one `isPresented` sheet per view, so two stacked picker sheets
    /// silently collided (the image picker never presented). One enum-routed sheet
    /// fixes that.
    @State private var activeSheet: ActiveSheet?

    private enum ActiveSheet: String, Identifiable {
        case image, model
        var id: String { rawValue }
    }

    /// The URL currently held under a security scope, if any. nil before the
    /// first pick. Every transition that mutates this balances start/stop in
    /// pairs — see `pick(url:)` and `onDisappear`.
    @State private var scopedURL: URL?

    /// Image content types for the document picker — covers png / jpeg / heic
    /// and any other image-conforming UTI.
    private static let imageContentTypes: [UTType] = [.image]

    /// Core ML model content types for the custom-model importer.
    private static let modelContentTypes: [UTType] = {
        var types: [UTType] = []
        if let pkg = UTType(filenameExtension: "mlpackage") { types.append(pkg) }
        if let model = UTType(filenameExtension: "mlmodel") { types.append(model) }
        types.append(.package)
        return types
    }()

    var body: some View {
        @Bindable var modelSelection = modelSelection
        NavigationStack {
            VStack(spacing: 0) {
                ImageDetailView(
                    coordinator: coordinator,
                    catalog: catalog,
                    recentDetectors: recentDetectors,
                    modelStore: modelStore,
                    selectedDetectorID: $modelSelection.detectorID,
                    showTuning: $showTuning
                )

                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }

                mruSection
            }
            .navigationTitle("Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        activeSheet = .image
                    } label: {
                        Label("Open image", systemImage: "photo.on.rectangle")
                    }
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .image:
                DocumentPicker(contentTypes: Self.imageContentTypes) { url in
                    activeSheet = nil
                    pick(url: url)
                }
                .ignoresSafeArea()
            case .model:
                DocumentPicker(contentTypes: Self.modelContentTypes) { url in
                    activeSheet = nil
                    loadPickedModel(at: url)
                }
                .ignoresSafeArea()
            }
        }
        .task {
            // M9·P2: launch selection is the shared `ModelSelection.detectorID`
            // (persisted + shared with Playback) — no per-page MRU launch read.
            // If the shared id is stale (not in this catalog), fall back to the
            // catalog's first entry so resolve never lands on nothing. Then warm
            // the bundled Core ML models off the main actor.
            if catalog.entries.first(where: { $0.id == selectedDetectorID }) == nil,
                let first = catalog.entries.first
            {
                modelSelection.detectorID = first.id
            }
            await modelStore.prewarmBundledModels()
        }
        .onChange(of: selectedDetectorID) {
            if selectedDetectorID == DemoCatalog.customEntryID,
                modelStore.availability(forEntryID: DemoCatalog.customEntryID) == .modelNotReady
            {
                activeSheet = .model
            }
            recentDetectors.addOrPromote(id: selectedDetectorID)
            selectDetector()
        }
        // M9·P2: the shared selection can change while this tab is off-screen
        // (e.g. switched on the Playback tab). On re-appear, re-run the held
        // frame under the shared detector if it drifted from what's installed —
        // skipping a redundant re-detect when already on the shared selection.
        .onAppear { syncCoordinatorToSharedSelection() }
        // M8·P5: consume a freeze-from-live request. Keyed on the token so a
        // re-inspect of the same frame still fires. Runs once on appear (in case
        // the request was posted while this tab was off-screen) and on each new
        // token.
        .task(id: handoff.request?.token) {
            await consumeInspectRequestIfPresent()
        }
        .onDisappear {
            let priorScopedURL = scopedURL
            scopedURL = nil
            showTuning = false
            coordinator.clear()
            priorScopedURL?.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Recent images list

    /// MRU list below the detail. Tap a row to re-pick that image. Hidden when
    /// empty (the toolbar "Pick image" button is the CTA).
    @ViewBuilder
    private var mruSection: some View {
        let recents = recentImages.resolve()
        if !recents.isEmpty {
            List {
                Section("Recent images") {
                    ForEach(recents, id: \.self) { url in
                        Button {
                            pick(url: url)
                        } label: {
                            HStack {
                                Image(systemName: "photo")
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

    // MARK: - Pick → decode → set

    /// Pick `url`: acquire its security scope, register it in the MRU, decode it
    /// to an upright `Frame`, hand the frame + resolved detector to the
    /// coordinator, then release the PRIOR scope strictly after `setImage`
    /// returns (the sandbox-scope ordering contract — the decode reads from the
    /// new URL while the old scope is still live, then the old scope drops).
    @MainActor
    private func pick(url: URL) {
        guard let entry = resolvedEntry else { return }

        guard url.startAccessingSecurityScopedResource() else {
            let message = "Could not access \(url.lastPathComponent) (security scope denied)."
            Logger.image.error(
                "startAccessingSecurityScopedResource failed for \(url.path, privacy: .public)"
            )
            errorText = message
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
            Logger.image.error("\(message, privacy: .public)")
            errorText = message
            return
        }

        let priorScopedURL = scopedURL
        scopedURL = url
        errorText = nil
        syncedDetectorID = entry.id

        Task { @MainActor in
            await coordinator.setImage(frame, detector: entry)
            // The decode is done and the coordinator holds the upright pixel
            // buffer in memory — the new URL's scope can be released too, but we
            // keep it for parity with the playback contract (the prior scope is
            // released here; the current one drops on the next pick / disappear).
            if let priorScopedURL {
                priorScopedURL.stopAccessingSecurityScopedResource()
            }
        }
    }

    /// M8·P5: if a freeze-from-live request is pending, open its frame in the
    /// inspector on the live source's detector, then clear the request. Selects
    /// the request's detector id (resolving it through the catalog, falling back
    /// to the first entry if it isn't selectable here — e.g. capture's
    /// `vision.rectangles` is always present, so the fallback is belt-and-braces)
    /// and runs detection on the frozen still via `setImage`.
    @MainActor
    private func consumeInspectRequestIfPresent() async {
        guard let request = handoff.request else { return }

        let entry = catalog.entries.first(where: { $0.id == request.detectorID })
            ?? catalog.entries.first
        guard let entry else { return }

        // M9·P2: write the live source's detector into the shared selection so
        // the whole app (incl. Playback) reflects what the inspector ran.
        modelSelection.detectorID = entry.id
        recentDetectors.addOrPromote(id: entry.id)
        syncedDetectorID = entry.id
        await coordinator.setImage(request.frame, detector: entry)

        // Consumed — clear so a later identical inspect re-fires via a new token.
        handoff.request = nil
    }

    /// Re-run detection on the held image under the newly-selected detector.
    @MainActor
    private func selectDetector() {
        guard let entry = resolvedEntry else { return }
        syncedDetectorID = entry.id
        Task { @MainActor in
            await coordinator.selectDetector(entry)
        }
    }

    /// M9·P2: re-run the held frame under the shared selection if it drifted
    /// while this page was off-screen. No-op when no frame is held yet (a pick
    /// / inspect installs the resolved entry itself and sets `syncedDetectorID`)
    /// or when the coordinator is already on the shared id (guards a redundant
    /// re-detect on every appear).
    @MainActor
    private func syncCoordinatorToSharedSelection() {
        guard coordinator.frame != nil, let entry = resolvedEntry else { return }
        guard syncedDetectorID != entry.id else { return }
        selectDetector()
    }

    /// Load a file-picked Path-A model, then re-select the custom entry so the
    /// detector-swap flow re-runs the held image under the freshly-loaded model.
    @MainActor
    private func loadPickedModel(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            await modelStore.loadPickedModel(at: url)
            if selectedDetectorID == DemoCatalog.customEntryID {
                selectDetector()
            } else {
                modelSelection.detectorID = DemoCatalog.customEntryID
            }
        }
    }
}

extension Logger {
    fileprivate static let image = Logger(subsystem: "iris.demo", category: "image")
}
