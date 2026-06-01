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
/// (`SidebarSection`/`SidebarSectionHeader`, `ModeSection`) plus `SourcePicker`.
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

    // Image page.
    let recentImages: [URL]
    let onOpenImage: () -> Void
    let onPickImage: (URL) -> Void

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
            // DATASET footer. The three selectable `ModeSection`s form an
            // accordion keyed to `page`: expanding a section IS selecting it,
            // and the others collapse. The expansion animation lives here
            // (keyed on `page`) so it drives the whole scroll block — matching
            // the original placement; each section owns its own header + content
            // layout.
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ModeSection(page: .playback, selection: $page) {
                        SourcePicker(
                            openTitle: "Open Video…",
                            openSystemImage: "folder.badge.plus",
                            onOpen: onOpenVideo,
                            recents: recentVideos,
                            recentSystemImage: "play.rectangle",
                            onPick: onPickVideo,
                            emptyHint: "Use Open Video… to pick a clip."
                        )
                    }
                    Divider().padding(.horizontal, 12)
                    ModeSection(page: .image, selection: $page) {
                        SourcePicker(
                            openTitle: "Open Image…",
                            openSystemImage: "photo.badge.plus",
                            onOpen: onOpenImage,
                            recents: recentImages,
                            recentSystemImage: "photo",
                            onPick: onPickImage,
                            emptyHint: "Use Open Image… to pick a still."
                        )
                    }
                    Divider().padding(.horizontal, 12)
                    ModeSection(page: .capture, selection: $page, isEnabled: captureAvailable) {
                        Text("Live camera")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        recentImages: PreviewFixtures.sampleImageURLs,
        onOpenImage: {},
        onPickImage: { _ in },
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
        recentImages: [],
        onOpenImage: {},
        onPickImage: { _ in },
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
        recentImages: PreviewFixtures.sampleImageURLs,
        onOpenImage: {},
        onPickImage: { _ in },
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
        recentImages: PreviewFixtures.sampleImageURLs,
        onOpenImage: {},
        onPickImage: { _ in },
        exportedFrameCountText: "12 frames exported",
        isSweeping: true,
        lastSummaryText: "Last sweep: 8 frames → ~/Datasets/iris (3.2 MB)",
        onExportNow: {},
        onRevealInFinder: {}
    )
    .frame(width: 280, height: 700)
}
#endif
