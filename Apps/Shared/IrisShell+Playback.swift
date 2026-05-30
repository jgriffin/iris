#if os(macOS)
import AppKit
#endif
import Iris
import SwiftUI
import UniformTypeIdentifiers
import os

// MARK: - Playback detail + lifecycle (M9·P3)
//
// Donated from the macOS `ContentView` / iOS `PlaybackContentView` playback
// halves. The `PlaybackView` + `DetectionLayer` + `Scrubber` rendering is left
// intact (Step 3 extracts it into a shared `PlaybackDetailView`); this hosts it
// and owns the file-pick / security-scope / MRU plumbing.
extension IrisShell {

    // MARK: Detail

    @ViewBuilder
    var playbackDetail: some View {
        VStack(spacing: 0) {
            if let controller = coordinator.controller {
                playbackArea(controller: controller)

                Scrubber(model: controller) {
                    if let flaggingModel {
                        FlagMarkerStrip(model: flaggingModel, duration: controller.duration)
                    }
                }
                #if os(macOS)
                .background(Color(.windowBackgroundColor))
                #endif

                bottomBar
            } else if let errorText {
                playbackError(errorText)
            } else {
                #if os(iOS)
                ProgressView("Loading fixture…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #else
                playbackEmptyState
                #endif
            }
        }
    }

    @ViewBuilder
    private func playbackArea(controller: PlaybackController) -> some View {
        ZStack {
            PlaybackView(source: controller.source)
                .id(ObjectIdentifier(controller.source))

            DetectionLayer(
                store: coordinator.resultStore,
                makeConverter: { [controller] size in
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
                minConfidence: Float(modelSelection.minConfidence),
                displayTimeSource: { [controller] in
                    MainActor.assumeIsolated { controller.currentTime }
                }
            )
            .allowsHitTesting(false)
        }
        // On-frame affordances, top-right of the actual video IMAGE.
        .overlay {
            VideoRectAligned(
                contentSize: controller.presentationSize,
                alignment: .topTrailing
            ) {
                HStack(spacing: 8) {
                    inspectButton(frameProvider: { coordinator.currentFrame })
                    if let flaggingModel {
                        FlagButton(model: flaggingModel)
                    }
                }
                .padding(12)
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
                Text(coordinator.metrics.compactSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        #if os(macOS)
        .background(Color(.windowBackgroundColor))
        #endif
    }

    @ViewBuilder
    private var playbackEmptyState: some View {
        VStack(spacing: 16) {
            if let errorText {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(errorText).multilineTextAlignment(.center).padding(.horizontal)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Open a video file to start.").foregroundStyle(.secondary)
            }
            Button("Open Video…") { presentVideoPicker() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func playbackError(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center).padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Inspect frame" — freeze the visible live frame and open it on the Image
    /// page under the SAME detector. Direct hand-off: one shell holds both
    /// coordinators (no `InspectorHandoff` conduit — M9·P3·5).
    @ViewBuilder
    func inspectButton(frameProvider: @escaping () -> Frame?) -> some View {
        Button {
            inspectFrame(frameProvider())
        } label: {
            Image(systemName: "camera.viewfinder")
                .font(.title3)
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(frameProvider() == nil)
        .help("Inspect this frame on the Image page")
        .accessibilityLabel("Inspect frame")
    }

    // MARK: Lifecycle

    /// Resolve the bundled fixture and load it (iOS first-launch default; the
    /// asset is inside the bundle so no security scope is needed).
    @MainActor
    func loadFixture() {
        guard let entry = resolvedEntry else { return }
        guard let url = Bundle.main.url(forResource: "clipboard-blank-page", withExtension: "mp4") else {
            errorText = "Bundled fixture clipboard-blank-page.mp4 not found in app bundle."
            Logger.shell.error("Bundled fixture missing from app bundle")
            return
        }
        errorText = nil
        activeLabel = "Bundled fixture"
        syncedVideoDetectorID = entry.id
        let source = PlaybackSource(url: url)
        Task { @MainActor in
            await coordinator.setSource(source, detector: entry)
            await flaggingModel?.setAsset(url: url)
            coordinator.controller?.togglePlay()
        }
    }

    /// Swap the active source to an external (picker- or MRU-supplied) URL.
    /// Scope ordering matches the prior demos: acquire new scope before
    /// `setSource`, release the prior scope strictly after it returns.
    @MainActor
    func swapToExternal(url: URL) {
        guard let entry = resolvedEntry else { return }
        if page != .playback { page = .playback }

        guard url.startAccessingSecurityScopedResource() else {
            errorText = "Could not access \(url.lastPathComponent) (security scope denied)."
            Logger.shell.error("startAccessingSecurityScopedResource failed for \(url.path, privacy: .public)")
            return
        }

        withAnimation(.snappy) { recentVideos.addOrPromote(url) }

        let priorScopedURL = scopedURL
        scopedURL = url
        activeLabel = url.lastPathComponent
        errorText = nil
        syncedVideoDetectorID = entry.id

        let source = PlaybackSource(url: url)
        Task { @MainActor in
            await coordinator.setSource(source, detector: entry)
            if let priorScopedURL { priorScopedURL.stopAccessingSecurityScopedResource() }
            await flaggingModel?.setAsset(url: url)
            coordinator.controller?.togglePlay()
        }
    }

    /// Re-run the playback coordinator under the shared selection.
    @MainActor
    func swapDetector() {
        guard let entry = resolvedEntry else { return }
        syncedVideoDetectorID = entry.id
        Task { @MainActor in await coordinator.selectDetector(entry) }
    }

    // MARK: File pickers

    /// Present the platform video picker (macOS `.fileImporter`; iOS sheet).
    func presentVideoPicker() {
        #if os(macOS)
        activeImporter = .movie
        #else
        showVideoPicker = true
        #endif
    }

    #if os(macOS)
    /// Load a file-picked Core ML model, then re-select the custom entry so the
    /// swap flow runs the freshly-loaded detector across both coordinators.
    @MainActor
    func loadPickedModel(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            await modelStore.loadPickedModel(at: url)
            if selectedDetectorID == DemoCatalog.customEntryID {
                swapDetector()
                selectImageDetector()
            } else {
                modelSelection.detectorID = DemoCatalog.customEntryID
            }
        }
    }
    #else
    @MainActor
    func loadPickedModel(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            await modelStore.loadPickedModel(at: url)
            if selectedDetectorID == DemoCatalog.customEntryID {
                swapDetector()
                selectImageDetector()
            } else {
                modelSelection.detectorID = DemoCatalog.customEntryID
            }
        }
    }
    #endif

    // MARK: Dataset count (read-only)

    static var framesDir: URL {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents
            .appendingPathComponent("iris-dataset", isDirectory: true)
            .appendingPathComponent("frames", isDirectory: true)
    }

    @MainActor
    func refreshExportedFrameCount() {
        let dir = Self.framesDir
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        exportedFrameCount = urls.filter { $0.pathExtension.lowercased() == "png" }.count
    }
}

#if os(macOS)
/// The two macOS root-view importers (movie + Core ML model), collapsed into one
/// routed `.fileImporter` — SwiftUI honors only one `isPresented` importer per
/// view (the image importer rides a separate modifier).
enum ActiveImporter: String, Identifiable {
    case movie, model
    var id: String { rawValue }

    var contentTypes: [UTType] {
        switch self {
        case .movie: return IrisShell.movieContentTypes
        case .model: return IrisShell.modelContentTypes
        }
    }
}
#endif

extension IrisShell {
    static let movieContentTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie]
    static let modelContentTypes: [UTType] = {
        var types: [UTType] = []
        if let pkg = UTType(filenameExtension: "mlpackage") { types.append(pkg) }
        if let model = UTType(filenameExtension: "mlmodel") { types.append(model) }
        types.append(.package)
        return types
    }()
    static let imageContentTypes: [UTType] = [.image]
}
