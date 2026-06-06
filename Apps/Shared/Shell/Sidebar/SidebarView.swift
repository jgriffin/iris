import Iris
import SwiftUI

/// The unified sidebar content (M9·P3): the `MODEL` section pinned to the top
/// (detector picker + the render-time min-confidence slider), the page-rows in
/// the middle (Playback / Image / Capture — the active row expands inline to
/// reveal its `Open…` button + `RECENT` list; inactive rows collapse to a bare
/// label), and a `DATASET` strip pinned to the bottom (macOS-only export
/// controls; read-only exported-frame count everywhere).
///
/// **One long-lived view.** This is the content of the shell's
/// `NavigationSplitView` sidebar column; it lives for the shell's lifetime.
/// Only row expansion toggles as the active page changes — there is no
/// per-page disappear / reload (that's what removes A4/A7).
///
/// **Thin assembler (M9·P6·3).** This view owns only the outer skeleton — the
/// pinned MODEL header, the divider, the scrolling block of page-sections, and
/// the pinned DATASET footer. It lists the five sections explicitly (no
/// `ForEach`): `ModelSection`, then the three selectable `ModeSection`s
/// (Playback / Image / Capture), then `DatasetSection`. The mode sections are
/// built from the design-language primitives in `Sidebar/Components/`
/// (`SidebarSection`/`SidebarSectionHeader`, `ModeSection`) plus `RecentList`.
/// The public init is unchanged so the `IrisShell` call site and previews are
/// untouched.
///
/// Cross-platform. macOS has no camera, so the Capture row renders disabled
/// there (gated on `captureAvailable`). The file-pick affordances differ per
/// platform (macOS `.fileImporter` vs. iOS `DocumentPicker`); the sidebar only
/// fires intent callbacks (`onOpenVideo` / `onOpenImage`) — the shell owns the
/// platform-specific picker plumbing.
struct SidebarView: View {
    @Binding var page: ShellPage

    // MODEL section.
    let catalog: DetectorCatalog
    let recentDetectors: RecentDetectors
    let modelStore: DemoModelStore
    @Bindable var modelSelection: ModelSelection
    let selectedDetectorID: String

    /// Whether Capture is offered on this platform (false on macOS — no camera).
    let captureAvailable: Bool

    // Playback page.
    let recentVideos: [URL]
    let onOpenVideo: () -> Void
    let onPickVideo: (URL) -> Void
    /// Forget a recent video from the MRU (context-menu).
    let onRemoveVideo: (URL) -> Void
    /// The picked video folders (MRU order) with their currently-enumerated
    /// matching children. The shell re-enumerates a folder on expand (see
    /// `onExpandVideoFolder`); children are empty until first opened.
    let videoFolders: [FoldersBlock.Folder]
    let onAddVideoFolder: () -> Void
    /// Load a folder *child* — same load path as a RECENT tap, plus the parent
    /// folder is promoted in the folders MRU (distinct from `onPickVideo`,
    /// which must NOT touch the folders MRU on a plain recents tap).
    let onPickVideoChild: (URL) -> Void
    let onExpandVideoFolder: (URL) -> Void
    /// Forget a video folder from the shared folders MRU (context-menu; never
    /// deletes the directory on disk).
    let onRemoveVideoFolder: (URL) -> Void

    // Image page.
    let recentImages: [URL]
    let onOpenImage: () -> Void
    let onPickImage: (URL) -> Void
    /// Forget a recent image from the MRU (context-menu).
    let onRemoveImage: (URL) -> Void
    let imageFolders: [FoldersBlock.Folder]
    let onAddImageFolder: () -> Void
    let onPickImageChild: (URL) -> Void
    let onExpandImageFolder: (URL) -> Void
    /// Forget an image folder from the shared folders MRU (context-menu).
    let onRemoveImageFolder: (URL) -> Void

    // DATASET strip. macOS-only export controls (iOS exposes Documents via
    // Files.app and never had this footer); the count line shows everywhere.
    let exportedFrameCountText: String
    /// Whether a dataset sweep is currently running (drives the progress spinner
    /// + disables the button). Always `false` on platforms without a coordinator.
    let isSweeping: Bool
    /// The last sweep's one-line summary, if any.
    let lastSummaryText: String?
    /// Export all flagged frames now. `nil` until a coordinator exists.
    let onExportNow: (() async -> Void)?
    /// Reveal the exported-frames folder in Finder. macOS-only (`nil` on iOS).
    let onRevealInFinder: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModelSection(
                catalog: catalog,
                recentDetectors: recentDetectors,
                modelStore: modelStore,
                modelSelection: modelSelection
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // The page-sections scroll between the pinned MODEL header and the
            // DATASET footer. The three selectable modes form an accordion keyed
            // to `page`: selecting a mode activates it and collapses the others.
            //
            // Sequential native pinning (M13·P4): the scroll content is a
            // `LazyVStack(pinnedViews: .sectionHeaders)`. The ACTIVE mode section
            // is flattened into sibling `Section`s — the accent header band, then
            // RECENT / FOLDERS / each open folder (emitted by `SourcesPanel`) —
            // so their headers pin sequentially, each deeper one replacing the
            // shallower as you scroll, and tapping a pinned header collapses it
            // (escape). INACTIVE modes + Capture render as bare, non-pinned rows.
            // The expansion animation stays keyed on `page` so activating a mode
            // animates the whole block as before.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    modeBlock(
                        page: .playback, openSystemImage: "folder.badge.plus", onOpen: onOpenVideo
                    ) {
                        SourcesPanel(
                            recents: recentVideos,
                            recentSystemImage: "film",
                            onPickRecent: onPickVideo,
                            recentEmptyHint: "No recent videos",
                            onRemoveRecent: onRemoveVideo,
                            folders: videoFolders,
                            folderChildSystemImage: "film",
                            onAddFolder: onAddVideoFolder,
                            onPickChild: onPickVideoChild,
                            onExpandFolder: onExpandVideoFolder,
                            onRemoveFolder: onRemoveVideoFolder
                        )
                    }
                    Divider().padding(.horizontal, 12)
                    modeBlock(
                        page: .image, openSystemImage: "photo.badge.plus", onOpen: onOpenImage
                    ) {
                        SourcesPanel(
                            recents: recentImages,
                            recentSystemImage: "photo",
                            onPickRecent: onPickImage,
                            recentEmptyHint: "No recent images",
                            onRemoveRecent: onRemoveImage,
                            folders: imageFolders,
                            folderChildSystemImage: "photo",
                            onAddFolder: onAddImageFolder,
                            onPickChild: onPickImageChild,
                            onExpandFolder: onExpandImageFolder,
                            onRemoveFolder: onRemoveImageFolder
                        )
                    }
                    Divider().padding(.horizontal, 12)
                    // Capture: no file source. Active → bare "Live camera" inside
                    // a pinned header band; inactive/disabled → bare row.
                    if page == .capture && captureAvailable {
                        Section {
                            Text("Live camera")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .sourcesContent()
                        } header: {
                            ModeHeaderBand(page: .capture)
                                .sidebarAccentBar()
                                .pinnedHeaderBackground(SidebarBand.headerTint)
                        }
                    } else {
                        ModeInactiveRow(page: .capture, isEnabled: captureAvailable) {
                            page = .capture
                        }
                    }
                }
                .padding(.vertical, 8)
                .animation(.snappy(duration: 0.22), value: page)
            }

            Spacer(minLength: 0)

            // The pinned DATASET footer. The divider was originally the first
            // element of `datasetStrip`; it now sits here in the skeleton, with
            // the strip's own 12/10 padding wrapping the section.
            Divider()
            DatasetSection(
                exportedFrameCountText: exportedFrameCountText,
                isSweeping: isSweeping,
                lastSummaryText: lastSummaryText,
                onExportNow: onExportNow,
                onRevealInFinder: onRevealInFinder
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    /// Emit one selectable mode into the pinning `LazyVStack`. When active, the
    /// mode's accent header band is a pinnable `Section` header (the top-level
    /// context pin — it stays put as you scroll, replaced only by the deeper
    /// RECENT/FOLDERS/open-folder pins), followed by the `sources` sub-block's own
    /// flattened `Section`s. When inactive, a bare non-pinned row that selects the
    /// mode on tap. The flattened pieces land as direct siblings of the LazyVStack
    /// so they pin sequentially. (The band itself has no collapse-tap — a mode is
    /// selected, not collapsed; the `onOpen` button is its only action. The
    /// tap-to-escape behavior lives on the deeper pins: the RECENT/FOLDERS
    /// chevrons and the open-folder row.)
    @ViewBuilder
    private func modeBlock(
        page modePage: ShellPage,
        openSystemImage: String,
        onOpen: @escaping () -> Void,
        @ViewBuilder sources: () -> some View
    ) -> some View {
        if page == modePage {
            Section {
                EmptyView()
            } header: {
                ModeHeaderBand(page: modePage, onOpen: onOpen, openSystemImage: openSystemImage)
                    .sidebarAccentBar()
                    .pinnedHeaderBackground(SidebarBand.headerTint)
            }
            sources()
        } else {
            ModeInactiveRow(page: modePage) { page = modePage }
        }
    }
}

// MARK: - Previews

#if DEBUG
/// The same preview block renders on whichever scheme is selected in the Xcode
/// canvas (iOS or macOS). The macOS-only `#if os(macOS)` export controls in the
/// DATASET strip naturally appear on the Mac scheme and vanish on iOS — that
/// cross-platform behavior is the point, so the previews don't fork per
/// platform. Each case constructs a real `SidebarView` from `PreviewFixtures`.

#Preview("Playback · populated") {
    @Previewable @State var page: ShellPage = .playback
    let store = PreviewFixtures.modelStore
    SidebarView(
        page: $page,
        catalog: PreviewFixtures.catalog(store: store),
        recentDetectors: PreviewFixtures.recentDetectors,
        modelStore: store,
        modelSelection: PreviewFixtures.modelSelection,
        selectedDetectorID: "vision.rectangles",
        captureAvailable: true,
        recentVideos: PreviewFixtures.sampleVideoURLs,
        onOpenVideo: {},
        onPickVideo: { _ in },
        onRemoveVideo: { _ in },
        videoFolders: PreviewFixtures.sampleVideoFolders,
        onAddVideoFolder: {},
        onPickVideoChild: { _ in },
        onExpandVideoFolder: { _ in },
        onRemoveVideoFolder: { _ in },
        recentImages: PreviewFixtures.sampleImageURLs,
        onOpenImage: {},
        onPickImage: { _ in },
        onRemoveImage: { _ in },
        imageFolders: PreviewFixtures.sampleImageFolders,
        onAddImageFolder: {},
        onPickImageChild: { _ in },
        onExpandImageFolder: { _ in },
        onRemoveImageFolder: { _ in },
        exportedFrameCountText: "12 frames exported",
        isSweeping: false,
        lastSummaryText: nil,
        onExportNow: {},
        onRevealInFinder: {}
    )
    .frame(width: 280, height: 700)
}

#Preview("Image · empty RECENT") {
    @Previewable @State var page: ShellPage = .image
    let store = PreviewFixtures.modelStore
    SidebarView(
        page: $page,
        catalog: PreviewFixtures.catalog(store: store),
        recentDetectors: PreviewFixtures.recentDetectors,
        modelStore: store,
        modelSelection: PreviewFixtures.modelSelection,
        selectedDetectorID: "vision.rectangles",
        captureAvailable: true,
        recentVideos: [],
        onOpenVideo: {},
        onPickVideo: { _ in },
        onRemoveVideo: { _ in },
        videoFolders: [],
        onAddVideoFolder: {},
        onPickVideoChild: { _ in },
        onExpandVideoFolder: { _ in },
        onRemoveVideoFolder: { _ in },
        recentImages: [],
        onOpenImage: {},
        onPickImage: { _ in },
        onRemoveImage: { _ in },
        imageFolders: [],
        onAddImageFolder: {},
        onPickImageChild: { _ in },
        onExpandImageFolder: { _ in },
        onRemoveImageFolder: { _ in },
        exportedFrameCountText: "No frames exported yet",
        isSweeping: false,
        lastSummaryText: nil,
        onExportNow: nil,
        onRevealInFinder: nil
    )
    .frame(width: 280, height: 700)
}

#Preview("Capture active") {
    @Previewable @State var page: ShellPage = .capture
    let store = PreviewFixtures.modelStore
    SidebarView(
        page: $page,
        catalog: PreviewFixtures.catalog(store: store),
        recentDetectors: PreviewFixtures.recentDetectors,
        modelStore: store,
        modelSelection: PreviewFixtures.modelSelection,
        selectedDetectorID: "vision.rectangles",
        captureAvailable: true,
        recentVideos: PreviewFixtures.sampleVideoURLs,
        onOpenVideo: {},
        onPickVideo: { _ in },
        onRemoveVideo: { _ in },
        videoFolders: PreviewFixtures.sampleVideoFolders,
        onAddVideoFolder: {},
        onPickVideoChild: { _ in },
        onExpandVideoFolder: { _ in },
        onRemoveVideoFolder: { _ in },
        recentImages: PreviewFixtures.sampleImageURLs,
        onOpenImage: {},
        onPickImage: { _ in },
        onRemoveImage: { _ in },
        imageFolders: PreviewFixtures.sampleImageFolders,
        onAddImageFolder: {},
        onPickImageChild: { _ in },
        onExpandImageFolder: { _ in },
        onRemoveImageFolder: { _ in },
        exportedFrameCountText: "12 frames exported",
        isSweeping: false,
        lastSummaryText: nil,
        onExportNow: nil,
        onRevealInFinder: nil
    )
    .frame(width: 280, height: 700)
}

#Preview("Sweeping") {
    @Previewable @State var page: ShellPage = .playback
    let store = PreviewFixtures.modelStore
    SidebarView(
        page: $page,
        catalog: PreviewFixtures.catalog(store: store),
        recentDetectors: PreviewFixtures.recentDetectors,
        modelStore: store,
        modelSelection: PreviewFixtures.modelSelection,
        selectedDetectorID: "vision.rectangles",
        captureAvailable: true,
        recentVideos: PreviewFixtures.sampleVideoURLs,
        onOpenVideo: {},
        onPickVideo: { _ in },
        onRemoveVideo: { _ in },
        videoFolders: PreviewFixtures.sampleVideoFolders,
        onAddVideoFolder: {},
        onPickVideoChild: { _ in },
        onExpandVideoFolder: { _ in },
        onRemoveVideoFolder: { _ in },
        recentImages: PreviewFixtures.sampleImageURLs,
        onOpenImage: {},
        onPickImage: { _ in },
        onRemoveImage: { _ in },
        imageFolders: PreviewFixtures.sampleImageFolders,
        onAddImageFolder: {},
        onPickImageChild: { _ in },
        onExpandImageFolder: { _ in },
        onRemoveImageFolder: { _ in },
        exportedFrameCountText: "12 frames exported",
        isSweeping: true,
        lastSummaryText: "Last sweep: 8 frames → ~/Datasets/iris (3.2 MB)",
        onExportNow: {},
        onRevealInFinder: {}
    )
    .frame(width: 280, height: 700)
}
#endif
