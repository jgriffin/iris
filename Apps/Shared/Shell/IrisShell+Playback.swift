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

    /// Hosts the shared `PlaybackDetailView` (M9·P3·3). The shell owns the
    /// coordinator / flagging / min-confidence / freeze-from-live; the detail
    /// view renders the player + overlay + scrubber + affordances. The chrome
    /// background is the only per-platform divergence.
    @ViewBuilder
    var playbackDetail: some View {
        #if os(macOS)
        let chrome = Color(.windowBackgroundColor)
        let loadingFixture = false
        #else
        let chrome = Color(.systemBackground)
        // iOS auto-loads a bundled fixture on first launch, so a nil controller
        // with no error is the loading state (not the empty state).
        let loadingFixture = (coordinator.controller == nil && errorText == nil)
        #endif
        PlaybackDetailView(
            coordinator: coordinator,
            flaggingModel: flaggingModel,
            filter: modelSelection.overlayFilter,
            activeLabel: activeLabel,
            errorText: errorText,
            isLoadingFixture: loadingFixture,
            onOpenVideo: presentVideoPicker,
            chromeBackground: chrome
        )
        // No detail-scoped toolbar here: ALL playback actions (Freeze + Flag)
        // live in the single main-window cluster, `IrisShell.detailToolbar`,
        // ordered [Freeze][Flag][Tune] (user call — never split them out).
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

    /// Present the video picker. One enum-routed importer per platform
    /// (`importTarget`) drives both the macOS `.fileImporter` and the iOS
    /// `DocumentPicker` sheet — see `IrisShell+Presentation`.
    func presentVideoPicker() {
        importTarget = .video
    }

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

    #if os(macOS)
    /// Reveal the exported-frames folder in Finder (creating it if missing).
    /// macOS-only — `NSWorkspace` is AppKit, and the DATASET footer is macOS-only.
    @MainActor
    func revealFramesInFinder() {
        let dir = Self.framesDir
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
    #endif
}

/// The single demo importer target. Every file-pick flow — pick a video, pick
/// an image, load a custom Core ML model — routes through ONE importer per
/// platform driven by `IrisShell.importTarget`; the completion dispatches by
/// case (M9·P5). Generalizes the P1 macOS movie+model `ActiveImporter` so the
/// shell carries one importer state and one dispatch instead of five flags and
/// two parallel modifiers.
enum ImportTarget: String, Identifiable, CaseIterable {
    case video, image, model
    var id: String { rawValue }

    var contentTypes: [UTType] {
        switch self {
        case .video: return IrisShell.movieContentTypes
        case .image: return IrisShell.imageContentTypes
        case .model: return IrisShell.modelContentTypes
        }
    }
}

extension IrisShell {
    /// Dispatch a picked `url` to the per-target pick handler. The handlers own
    /// security-scope + MRU; this just routes by case.
    @MainActor
    func handlePicked(_ url: URL, for target: ImportTarget) {
        switch target {
        case .video: swapToExternal(url: url)
        case .image: pickImage(url: url)
        case .model: loadPickedModel(at: url)
        }
    }

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
