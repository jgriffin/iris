#if DEBUG
import SwiftUI

// MARK: - FOLDER-block design gallery (M13·P3a — the favorite pattern)
//
// A throwaway canvas (this whole file is deleted-or-trimmed in the P3 wiring
// half) that makes the two ⚖️ opens comparable at a glance — settle them HERE,
// in the canvas, not on paper (folder-sources.md §Opens):
//
//   • PLACEMENT — the FOLDERS block ABOVE vs BELOW the RECENT list, shown in
//     real `ModeSection` anatomy (accent bar + 0.22 header band + 0.08 body) so
//     the surrounding section is visible while judging.
//   • PRESENTATION — `.independent` disclosure (open many) vs `.oneExpanded`
//     (accordion: opening one collapses the rest).
//
// …plus the edge cases that might swing either call: an empty folder, a
// ~12-child folder (P4's cap target), a folder block while RECENT is empty, and
// the inactive (collapsed) section — where the folder block should NOT render.
//
// `FolderBlock`/`FoldersBlock`/`PreviewFixtures.sample*Folders` survive; only
// the gallery scaffolding below is throwaway.

/// One labeled gallery entry: a caption (what the case asks the user to judge) +
/// the content boxed in a fixed-width frame so cases align and read as a matrix.
/// Mirrors `PerClassGalleryCase` (M12·P4) so the house gallery idiom stays one
/// shape.
private struct FolderGalleryCase<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .padding(10)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .frame(width: 300, alignment: .leading)
        }
    }
}

/// The active Playback section body, fixture-fed, with the FOLDERS block placed
/// either above or below the RECENT list. Built from the real `ModeSection` so
/// the placement judgement happens inside the true section anatomy. The page is
/// pinned active (`selection == .playback`) so the active treatment renders.
private struct PlacementCase: View {
    enum Placement { case above, below }
    let placement: Placement
    let presentation: FolderPresentation
    var folders: [FoldersBlock.Folder] = PreviewFixtures.sampleVideoFolders
    var recents: [URL] = PreviewFixtures.sampleVideoURLs

    @State private var page: ShellPage = .playback

    var body: some View {
        ModeSection(
            page: .playback, selection: $page,
            onOpen: {}, openSystemImage: "folder.badge.plus"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if placement == .above { foldersBlock }
                RecentList(
                    recents: recents,
                    systemImage: "film",
                    onPick: { _ in },
                    emptyHint: "No recent videos"
                )
                if placement == .below { foldersBlock }
            }
        }
    }

    private var foldersBlock: some View {
        FoldersBlock(
            folders: folders,
            childSystemImage: "film",
            presentation: presentation,
            onPickChild: { _ in }
        )
    }
}

/// The whole decision matrix as one stacked column. Rendered light + dark below.
@MainActor @ViewBuilder
private var folderGallery: some View {
    VStack(alignment: .leading, spacing: 22) {
        Text("FOLDER block — placement × presentation")
            .font(.headline)

        // ── Placement fork, in full section anatomy ──────────────────────
        // Same folders + RECENT either side, so the only variable is order.
        FolderGalleryCase(title: "Placement: FOLDERS above RECENT (section anatomy)") {
            PlacementCase(placement: .above, presentation: .independent)
        }
        FolderGalleryCase(title: "Placement: FOLDERS below RECENT (section anatomy)") {
            PlacementCase(placement: .below, presentation: .independent)
        }

        // ── Presentation fork ────────────────────────────────────────────
        // The folder stack on its own (no section chrome) so the disclosure
        // behavior is the only thing in frame. Tap folders in the canvas to
        // feel the difference: independent keeps siblings open; one-expanded
        // collapses them. Both start with the first folder open.
        FolderGalleryCase(title: "Presentation: INDEPENDENT — open many at once") {
            FoldersBlock(
                folders: PreviewFixtures.sampleVideoFolders,
                childSystemImage: "film",
                presentation: .independent,
                onPickChild: { _ in }
            )
        }
        FolderGalleryCase(title: "Presentation: ONE-EXPANDED — opening one collapses the rest") {
            FoldersBlock(
                folders: PreviewFixtures.sampleVideoFolders,
                childSystemImage: "film",
                presentation: .oneExpanded,
                onPickChild: { _ in }
            )
        }

        // ── Edge cases that might swing the call ─────────────────────────
        FolderGalleryCase(title: "Edge: empty folder — quiet 'no matching files'") {
            ExpandedSingleFolder(
                folder: PreviewFixtures.sampleEmptyVideoFolder,
                childSystemImage: "film"
            )
        }
        FolderGalleryCase(title: "Edge: many files (~12) — P4 cap target, no cap today") {
            ExpandedSingleFolder(
                folder: PreviewFixtures.sampleManyVideoFolder,
                childSystemImage: "film"
            )
        }
        FolderGalleryCase(title: "Edge: FOLDERS present while RECENT empty (section anatomy)") {
            PlacementCase(
                placement: .above, presentation: .independent,
                recents: []
            )
        }
        FolderGalleryCase(title: "Edge: image kind — photo child glyph") {
            FoldersBlock(
                folders: PreviewFixtures.sampleImageFolders,
                childSystemImage: "photo",
                presentation: .independent,
                onPickChild: { _ in }
            )
        }
        FolderGalleryCase(title: "Inactive section — collapses to a bare row, NO folder block") {
            InactiveSectionCase()
        }
    }
    .padding(16)
    .frame(width: 340)
}

/// A single folder pinned open — for the empty / many-files edge cases where the
/// children themselves are what's being judged.
private struct ExpandedSingleFolder: View {
    let folder: FoldersBlock.Folder
    let childSystemImage: String
    @State private var expanded = true

    var body: some View {
        FolderBlock(
            folderName: folder.name,
            folderURL: folder.url,
            children: folder.children,
            childSystemImage: childSystemImage,
            isExpanded: $expanded,
            onPickChild: { _ in }
        )
    }
}

/// The inactive (collapsed) Image section — `selection` is elsewhere, so
/// `ModeSection` draws the bare tappable row and the folder block we'd inject is
/// simply absent. Confirms the block doesn't leak into collapsed sections.
private struct InactiveSectionCase: View {
    @State private var page: ShellPage = .playback   // active elsewhere

    var body: some View {
        ModeSection(
            page: .image, selection: $page,
            onOpen: {}, openSystemImage: "photo.badge.plus"
        ) {
            // Never rendered while inactive — present only to mirror the active
            // body's shape.
            VStack(alignment: .leading, spacing: 12) {
                FoldersBlock(
                    folders: PreviewFixtures.sampleImageFolders,
                    childSystemImage: "photo",
                    presentation: .independent,
                    onPickChild: { _ in }
                )
                RecentList(
                    recents: PreviewFixtures.sampleImageURLs,
                    systemImage: "photo",
                    onPick: { _ in },
                    emptyHint: "No recent images"
                )
            }
        }
    }
}

#Preview("FOLDER gallery · light") {
    ScrollView { folderGallery }
        .preferredColorScheme(.light)
}

#Preview("FOLDER gallery · dark") {
    ScrollView { folderGallery }
        .preferredColorScheme(.dark)
}
#endif
