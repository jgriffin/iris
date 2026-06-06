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
            filter: overlayFilter,
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
    /// (`importerPresented` + the `importTarget` payload) drives both the
    /// macOS `.fileImporter` and the iOS `DocumentPicker` sheet — see
    /// `IrisShell+Presentation`.
    func presentVideoPicker() {
        presentImporter(for: .video)
    }

    /// Present the folder picker for Playback (movies). Mirrors
    /// `presentVideoPicker`; the `[.folder]` content type makes both pickers
    /// return a directory URL with security scope. Not yet called from any
    /// surface — the sidebar FOLDER block is M13·P3.
    func presentVideoFolderPicker() {
        presentImporter(for: .videoFolder)
    }

    /// Present the folder picker for Image (stills). Sibling of
    /// `presentVideoFolderPicker`; differs only in how children are filtered
    /// at enumeration time. Surface lands in M13·P3.
    func presentImageFolderPicker() {
        presentImporter(for: .imageFolder)
    }

    /// Handle a picked **folder**: register it in the shared folders MRU and
    /// enumerate its matching children once, end-to-end, to exercise the
    /// listing helper on a real pick (the live sidebar surface is M13·P3).
    ///
    /// Scope discipline mirrors `swapToExternal` / `pickImage`: acquire the
    /// folder's security scope, do the scoped work (MRU bookmark creation reads
    /// the URL; `folderListing` reads the directory), then release. Both folder
    /// kinds share ONE MRU — a folder of clips and a folder of stills are both
    /// just folders; the per-mode filter (`kind`) is applied here at
    /// enumeration time, not at storage time.
    @MainActor
    func pickFolder(url: URL, kind: FolderContentKind) {
        guard url.startAccessingSecurityScopedResource() else {
            Logger.shell.error(
                "startAccessingSecurityScopedResource failed for folder \(url.path, privacy: .public)"
            )
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        recentFolders.addOrPromote(url)
        let children = folderListing(of: url, kind: kind)
        Logger.shell.notice(
            """
            folder picked: \(url.lastPathComponent, privacy: .public) \
            (\(children.count) matching \(String(describing: kind), privacy: .public) children)
            """
        )
    }

    // MARK: Sidebar FOLDERS sub-block wiring (M13·P3)

    /// Build the FOLDERS sub-block's data for a mode from the shared folders MRU
    /// + the lazily-enumerated child cache. The MRU is one shared list (both
    /// modes); children are filtered per `kind` at enumeration time, so the same
    /// folder can show movies under Playback and stills under Image. Children are
    /// empty until the folder is first expanded (`enumerateFolderOnExpand`); the
    /// quiet zero count is honest until then.
    @MainActor
    func folderBlocks(kind: FolderContentKind) -> [FoldersBlock.Folder] {
        recentFolders.resolve().map { url in
            FoldersBlock.Folder(
                url: url,
                children: folderChildren[FolderChildKey(folder: url, kind: kind)] ?? []
            )
        }
    }

    /// Re-enumerate a folder's matching children when its disclosure opens
    /// (M13·P3) — the freshness model is re-enumerate-on-expand, so every open
    /// picks up files added/removed since last time. Wrapped in the folder's
    /// security scope (start/stop around the read), matching the house
    /// discipline in `pickFolder` / `swapToExternal`. The resolved URL carries a
    /// latent macOS scope; `folderListing` reads the directory while it's open.
    @MainActor
    func enumerateFolderOnExpand(url: URL, kind: FolderContentKind) {
        let key = FolderChildKey(folder: url, kind: kind)
        guard url.startAccessingSecurityScopedResource() else {
            Logger.shell.error(
                "startAccessingSecurityScopedResource failed for folder \(url.path, privacy: .public)"
            )
            folderChildren[key] = []
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        folderChildren[key] = folderListing(of: url, kind: kind)
    }

    /// Load a folder *child* and promote its parent folder in the folders MRU.
    /// Routes through the SAME load path as a RECENT tap (`load` is
    /// `swapToExternal` for movies, `pickImage` for stills) so navigation,
    /// RECENT promotion, and detector swap all behave identically — the child
    /// reuses the exact recents-tap plumbing.
    ///
    /// **Scope hand-off (macOS).** A child URL enumerated from a folder is a
    /// plain `file://` URL — it carries no bookmark scope of its own, so the
    /// load path's `startAccessingSecurityScopedResource()` on it would return
    /// `false` and the load would fail "security scope denied". The fix: under
    /// the parent folder's resolved (scoped) URL, mint a security-scoped
    /// bookmark for the child and resolve it back to a *scoped* child URL; the
    /// load path then acquires and holds the child's own scope for the session
    /// (AVAssetReader / decode read it lazily over time). On iOS this is a
    /// no-op transform (minimal bookmarks, no security scope) and the plain URL
    /// works either way. We also promote the parent folder so a freshly-used
    /// folder sorts up the MRU.
    @MainActor
    func pickFolderChild(url child: URL, load: (URL) -> Void) {
        // Find the parent among the resolved (scoped) MRU folders so we hold a
        // real scope while bookmarking the child. Fall back to the plain parent
        // path if it isn't in the MRU (shouldn't happen — the child came from
        // enumerating an MRU folder).
        let parentPath = child.deletingLastPathComponent().standardizedFileURL.path
        let scopedParent = recentFolders.resolve().first {
            $0.standardizedFileURL.path == parentPath
        }

        recentFolders.addOrPromote(scopedParent ?? child.deletingLastPathComponent())
        load(scopedChild(child, under: scopedParent) ?? child)
    }

    /// Promote a plain enumerated child URL to a security-scoped one by minting
    /// + resolving a bookmark while the parent folder's scope is held. Returns
    /// `nil` (caller falls back to the plain URL) if the parent has no scope or
    /// bookmarking fails. iOS uses minimal (unscoped) bookmarks, so the round
    /// trip is harmless there.
    @MainActor
    private func scopedChild(_ child: URL, under scopedParent: URL?) -> URL? {
        guard let scopedParent else { return nil }
        guard scopedParent.startAccessingSecurityScopedResource() else { return nil }
        defer { scopedParent.stopAccessingSecurityScopedResource() }

        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = [.minimalBookmark]
        let resolveOptions: URL.BookmarkResolutionOptions = []
        #endif

        do {
            let blob = try child.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
            var stale = false
            return try URL(resolvingBookmarkData: blob, options: resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            Logger.shell.error(
                "scopedChild: bookmark round-trip failed for \(child.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    // MARK: MRU entry removal (M13·P4)

    /// Forget a recent video from the videos MRU (sidebar "Remove from
    /// Recents"). Animated with the `.snappy` idiom used by `addOrPromote` so the
    /// row animates out and the RECENT count updates; never touches disk.
    @MainActor
    func removeRecentVideo(url: URL) {
        withAnimation(.snappy) { recentVideos.remove(url) }
    }

    /// Forget a folder from the shared folders MRU (sidebar "Remove Folder").
    /// Removes the MRU entry ONLY — it does not delete the directory. Animated so
    /// the folder row animates out and the FOLDERS count updates. Serves both
    /// modes (one shared folders MRU).
    @MainActor
    func removeFolder(url: URL) {
        withAnimation(.snappy) { recentFolders.remove(url) }
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
/// platform, presented by `IrisShell.importerPresented` with this enum as the
/// payload (`IrisShell.importTarget`); the completion dispatches by case
/// (M9·P5). Generalizes the P1 macOS movie+model `ActiveImporter` so the
/// shell carries one importer state and one dispatch instead of five flags and
/// two parallel modifiers.
//
// M13·P2 adds two **folder** cases (`videoFolder` / `imageFolder`), both with
// `contentTypes = [.folder]` — separate cases rather than a folder axis on the
// existing ones because the two kinds filter their children differently (movies
// vs. stills) and route to a folder handler, not to the single-file open flow.
enum ImportTarget: String, Identifiable, CaseIterable {
    case video, image, model
    case videoFolder, imageFolder
    var id: String { rawValue }

    var contentTypes: [UTType] {
        switch self {
        case .video: return IrisShell.movieContentTypes
        case .image: return IrisShell.imageContentTypes
        case .model: return IrisShell.modelContentTypes
        case .videoFolder, .imageFolder: return [.folder]
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
        case .videoFolder: pickFolder(url: url, kind: .movie)
        case .imageFolder: pickFolder(url: url, kind: .image)
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
