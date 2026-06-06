#if DEBUG
import SwiftUI

// MARK: - FOLDER-block design gallery (M13·P3 — the favorite pattern)
//
// The regression surface for the shipped FOLDERS design. The P3a canvas pass
// settled the two ⚖️ opens; the losers are gone:
//
//   • PLACEMENT — FOLDERS sits BELOW RECENT (a picked video lands at the top of
//     RECENT anyway, so RECENT is the hot zone). The above-RECENT variant is
//     deleted.
//   • PRESENTATION — one-expanded-at-a-time only (opening a folder collapses its
//     siblings). The `.independent` candidate + its `FolderPresentation` switch
//     are deleted.
//
// Shipped additions these cases exercise: RECENT and FOLDERS are each their own
// collapsible sub-block (header + chevron) inside the active section body; a
// quiet monospaced count rides every collapsible heading (RECENT, FOLDERS, each
// folder row); the FOLDERS header carries an `folder.badge.plus` add button and
// renders even with zero folders. Captions are statements of intended look (no
// longer questions to judge).
//
// `SourcesPanel` (the composed RECENT-over-FOLDERS body), `FoldersBlock`,
// `FolderBlock`, and `PreviewFixtures.sample*Folders` survive; only the gallery
// scaffolding below is throwaway.

/// One labeled gallery entry: a caption stating what the case demonstrates + the
/// content boxed in a fixed-width frame so cases align and read as a matrix.
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

/// The active Playback section body — the real `SourcesPanel` (RECENT over
/// FOLDERS) inside the real `ModeSection`, so placement + the two collapsible
/// sub-blocks are judged in true section anatomy (accent bar + 0.22 header band
/// + 0.08 body). Pinned active (`selection == .playback`) so the active
/// treatment renders.
private struct ActiveSectionCase: View {
    var folders: [FoldersBlock.Folder] = PreviewFixtures.sampleVideoFolders
    var recents: [URL] = PreviewFixtures.sampleVideoURLs

    @State private var page: ShellPage = .playback

    var body: some View {
        ModeSection(
            page: .playback, selection: $page,
            onOpen: {}, openSystemImage: "folder.badge.plus"
        ) {
            SourcesPanel(
                recents: recents,
                recentSystemImage: "film",
                onPickRecent: { _ in },
                recentEmptyHint: "No recent videos",
                folders: folders,
                folderChildSystemImage: "film",
                onAddFolder: {},
                onPickChild: { _ in },
                onExpandFolder: { _ in }
            )
        }
    }
}

/// The whole shipped-design matrix as one stacked column. Rendered light + dark.
@MainActor @ViewBuilder
private var folderGallery: some View {
    VStack(alignment: .leading, spacing: 22) {
        Text("FOLDERS — shipped design (below RECENT · collapsible sub-blocks · counts)")
            .font(.headline)

        // ── The shipped section body, in full anatomy ───────────────────
        FolderGalleryCase(title: "Active section: RECENT over FOLDERS, both expanded, counts on every heading") {
            ActiveSectionCase()
        }
        FolderGalleryCase(title: "RECENT collapsed to reach FOLDERS — the fast path the collapse exists for") {
            CollapsedRecentCase()
        }
        FolderGalleryCase(title: "Empty FOLDERS — header + add button still render so the first folder can be added") {
            ActiveSectionCase(folders: [])
        }
        FolderGalleryCase(title: "FOLDERS present while RECENT is empty (quiet recents hint)") {
            ActiveSectionCase(recents: [])
        }

        // ── One-expanded presentation, folder stack alone ────────────────
        // Tap folders in the canvas: opening one collapses its sibling with the
        // 0.22 snappy animation. First folder starts open.
        FolderGalleryCase(title: "One-expanded accordion — opening a folder collapses the sibling (animated)") {
            OneExpandedFoldersCase(folders: PreviewFixtures.sampleVideoFolders)
        }

        // ── Folder-row + child edge cases ────────────────────────────────
        FolderGalleryCase(title: "Folder row expanded — child rows subordinate, child count on the row") {
            ExpandedSingleFolder(
                folder: PreviewFixtures.sampleVideoFolders[0],
                childSystemImage: "film"
            )
        }
        FolderGalleryCase(title: "Empty folder — quiet 'no matching files', count reads 0") {
            ExpandedSingleFolder(
                folder: PreviewFixtures.sampleEmptyVideoFolder,
                childSystemImage: "film"
            )
        }
        FolderGalleryCase(title: "Many files (~12) — no cap today (scroll-inside vs. cap backlogged)") {
            ExpandedSingleFolder(
                folder: PreviewFixtures.sampleManyVideoFolder,
                childSystemImage: "film"
            )
        }
        FolderGalleryCase(title: "Image kind — photo child glyph, image-folder fixtures") {
            OneExpandedFoldersCase(
                folders: PreviewFixtures.sampleImageFolders,
                childSystemImage: "photo"
            )
        }
        FolderGalleryCase(title: "Inactive section — collapses to a bare row, NO sources body") {
            InactiveSectionCase()
        }
    }
    .padding(16)
    .frame(width: 340)
}

/// The shipped section body with RECENT pre-collapsed — demonstrates the fast
/// path to FOLDERS. `SourcesPanel` owns the sub-block expansion state, so the
/// collapse is driven by interaction; this case seeds the intent in its caption
/// (the canvas is where the user taps RECENT's chevron to verify).
private struct CollapsedRecentCase: View {
    @State private var page: ShellPage = .playback

    var body: some View {
        ModeSection(
            page: .playback, selection: $page,
            onOpen: {}, openSystemImage: "folder.badge.plus"
        ) {
            SourcesPanel(
                recents: PreviewFixtures.sampleVideoURLs,
                recentSystemImage: "film",
                onPickRecent: { _ in },
                recentEmptyHint: "No recent videos",
                folders: PreviewFixtures.sampleVideoFolders,
                folderChildSystemImage: "film",
                onAddFolder: {},
                onPickChild: { _ in },
                onExpandFolder: { _ in }
            )
        }
    }
}

/// The FOLDERS sub-block on its own (no section chrome) with the one-expanded
/// accordion live — for feeling the sibling-collapse animation. Owns the
/// sub-block + open-folder state the way `SourcesPanel` does, first folder open.
private struct OneExpandedFoldersCase: View {
    let folders: [FoldersBlock.Folder]
    var childSystemImage: String = "film"

    @State private var expanded = true
    @State private var openFolder: URL?

    var body: some View {
        FoldersBlock(
            folders: folders,
            childSystemImage: childSystemImage,
            isExpanded: $expanded,
            openFolder: $openFolder,
            onAddFolder: {},
            onPickChild: { _ in }
        )
        .onAppear { openFolder = folders.first?.url }
    }
}

/// A single folder pinned open — for the row / child edge cases where the
/// children + the child count on the row are what's being judged.
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
/// `ModeSection` draws the bare tappable row and the sources body we'd inject is
/// simply absent. Confirms the sub-blocks don't leak into collapsed sections.
private struct InactiveSectionCase: View {
    @State private var page: ShellPage = .playback   // active elsewhere

    var body: some View {
        ModeSection(
            page: .image, selection: $page,
            onOpen: {}, openSystemImage: "photo.badge.plus"
        ) {
            // Never rendered while inactive — present only to mirror the active
            // body's shape.
            SourcesPanel(
                recents: PreviewFixtures.sampleImageURLs,
                recentSystemImage: "photo",
                onPickRecent: { _ in },
                recentEmptyHint: "No recent images",
                folders: PreviewFixtures.sampleImageFolders,
                folderChildSystemImage: "photo",
                onAddFolder: {},
                onPickChild: { _ in },
                onExpandFolder: { _ in }
            )
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
