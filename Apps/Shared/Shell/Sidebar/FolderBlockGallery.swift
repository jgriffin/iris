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
// collapsible sub-block (whole-row tap target) inside the active section body; a
// quiet monospaced count rides every collapsible heading (RECENT, FOLDERS, each
// folder row); the FOLDERS header carries NO add button (smoke round 1 — the
// mode header's open button accepts a file OR a folder now), and the empty
// FOLDERS hint points there. Captions are statements of intended look (no longer
// questions to judge).
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
/// FOLDERS) inside the live FLATTENED anatomy: the mode header band + the
/// sources sub-blocks emitted as sibling `Section`s in a
/// `LazyVStack(pinnedViews: .sectionHeaders)`, exactly as `SidebarView` hosts
/// them (M13·P4). Judges placement + the collapsible sub-blocks + the pinned
/// headers in true shipped anatomy (accent bar + 0.22 header band + 0.08 body).
private struct ActiveSectionCase: View {
    var folders: [FoldersBlock.Folder] = PreviewFixtures.sampleVideoFolders
    var recents: [URL] = PreviewFixtures.sampleVideoURLs

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                Section {
                    EmptyView()
                } header: {
                    ModeHeaderBand(page: .playback, onOpen: {}, openSystemImage: "folder.badge.plus")
                        .sidebarAccentBar()
                        .pinnedHeaderBackground(SidebarBand.headerTint)
                }
                SourcesPanel(
                    recents: recents,
                    recentSystemImage: "film",
                    onPickRecent: { _ in },
                    recentEmptyHint: "No recent videos",
                    folders: folders,
                    folderChildSystemImage: "film",
                    onPickChild: { _ in },
                    onExpandFolder: { _ in }
                )
            }
        }
        .frame(height: 360)
    }
}

/// The whole shipped-design matrix as one stacked column. Rendered light + dark.
@MainActor @ViewBuilder
private var folderGallery: some View {
    VStack(alignment: .leading, spacing: 22) {
        Text("FOLDERS — shipped design (below RECENT · collapsible sub-blocks · counts · pinned headers · remove menus)")
            .font(.headline)

        // ── The shipped section body, in full anatomy ───────────────────
        FolderGalleryCase(title: "Active section: RECENT over FOLDERS, both expanded, counts on every heading") {
            ActiveSectionCase()
        }
        FolderGalleryCase(title: "RECENT collapsed to reach FOLDERS — the fast path the collapse exists for") {
            CollapsedRecentCase()
        }
        FolderGalleryCase(title: "Empty FOLDERS — header renders; hint points at the mode header's open button (no add button)") {
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
        FolderGalleryCase(title: "Context menus (M13·P4) — remove affordances; static note (menus don't render)") {
            ContextMenuNoteCase()
        }
    }
    .padding(16)
    .frame(width: 340)
}

/// The shipped section body in the flattened host — same as `ActiveSectionCase`,
/// captioned for the RECENT-collapse fast path. `SourcesPanel` owns the sub-block
/// expansion state, so the collapse is driven by tapping RECENT's chevron in the
/// canvas; this case seeds the intent in its caption.
private struct CollapsedRecentCase: View {
    var body: some View {
        ActiveSectionCase()
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

/// The inactive (collapsed) Image mode — a bare tappable `ModeInactiveRow`, no
/// sources body. In the live sidebar an inactive mode never emits the sub-block
/// `Section`s at all (they're conditional on `page == modePage`); this confirms
/// the collapsed row's look in isolation.
private struct InactiveSectionCase: View {
    var body: some View {
        ModeInactiveRow(page: .image) { }
    }
}

/// A captioned note row standing in for the context-menu affordance. Context
/// menus don't render statically (they appear only on right-click / long-press),
/// so this case documents the affordance rather than forcing a render — a RECENT
/// row + a folder row, each annotated with the menu item it carries.
private struct ContextMenuNoteCase: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            menuNote(
                glyph: "film", name: "clip-042.mov",
                note: "right-click / long-press → \u{201C}Remove from Recents\u{201D}"
            )
            menuNote(
                glyph: "folder", name: "Shoot — June",
                note: "right-click / long-press → \u{201C}Remove Folder\u{201D} (MRU only, never deletes on disk)"
            )
            menuNote(
                glyph: "film", name: "(folder child)",
                note: "no menu — children aren\u{2019}t MRU entries", muted: true
            )
        }
    }

    @ViewBuilder
    private func menuNote(glyph: String, name: String, note: String, muted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: glyph)
                    .frame(width: 20)
                    .foregroundStyle(muted ? .tertiary : .secondary)
                Text(name)
                    .foregroundStyle(muted ? .secondary : .primary)
            }
            Text(note)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 28)
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
