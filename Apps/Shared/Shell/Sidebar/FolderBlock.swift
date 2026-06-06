import SwiftUI

/// A quiet trailing item-count badge for a collapsible heading (M13·P3): the
/// "how much is in here" indicator the user asked for on every collapsible
/// heading — the RECENT header, the FOLDERS header, and each folder row.
/// Tertiary, caption-sized, monospaced-digit so counts don't reflow as they
/// change. Rendered in BOTH collapsed and expanded states (most valuable when
/// collapsed, harmless when expanded).
struct ItemCount: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
    }
}

/// One picked folder, drawn as a collapsible disclosure inside the FOLDERS
/// sub-block (M13·P3). The header is a folder row — folder glyph + name + a
/// trailing matching-child count + a chevron that rotates with the disclosure —
/// and, when expanded, the folder's matching children render as rows that
/// *rhyme* with `RecentList`: same icon + middle-truncated-name idiom, but
/// visually subordinate (a deeper indent and a quieter child glyph) so they read
/// as living *inside* the folder rather than as peers of the RECENT entries
/// above them. An empty folder shows a quiet "no matching files" caption in the
/// same indented slot.
///
/// **Section-split for native pinning (M13·P4).** The folder is no longer one
/// `VStack`; it exposes its header row (`folderRow`) and its children
/// (`childRows`) separately so the FOLDERS wrapper can wrap the open folder in a
/// `Section { childRows } header: { folderRow }`, letting the open folder's row
/// pin atop a long child list (the deepest pin, replacing the FOLDERS header).
/// The pieces are still preview-drivable directly via `body`, which recomposes
/// them into the original stacked look for the gallery.
///
/// **Plain data in, callbacks out — no state lookups.** The block takes the
/// folder name/URL, the already-enumerated `children`, an external expansion
/// `Binding`, and tap / remove callbacks. It never reads `RecentFolders`, never
/// calls `folderListing` — that wiring lives in the parent (`SourcesPanel` →
/// `IrisShell`). This keeps it fully preview-drivable (the gallery feeds it
/// fixture URLs that need not exist on disk) and keeps one-expanded-at-a-time
/// possible: the parent owns the expansion state and collapses siblings.
struct FolderBlock: View {
    let folderName: String
    /// The folder's own URL — used for the header tooltip (full path) and the
    /// "Remove Folder" context-menu callback.
    let folderURL: URL
    /// The matching children, already enumerated + filtered by the caller.
    let children: [URL]
    /// The per-kind glyph for child rows (`film` for movies, `photo` for
    /// stills) — distinct from, and quieter than, the RECENT rows' glyphs.
    let childSystemImage: String
    /// Whether this folder's disclosure is open. Owned by the parent so the
    /// FOLDERS sub-block can enforce one-expanded-at-a-time.
    @Binding var isExpanded: Bool
    /// Load a child (→ RECENT promotion happens at the wiring layer).
    let onPickChild: (URL) -> Void
    /// Forget this folder from the folders MRU (never touches disk). `nil` in the
    /// gallery where there's no MRU to mutate.
    var onRemoveFolder: ((URL) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            folderRow
            if isExpanded {
                childRows
                    .padding(.leading, 8)   // subordinate: deeper than RECENT rows
            }
        }
    }

    // MARK: Folder header row — glyph + name + count + disclosure chevron.

    /// The tappable folder row. Carries a "Remove Folder" destructive
    /// context-menu (right-click on macOS / long-press on iOS) that forgets the
    /// MRU entry — only when `onRemoveFolder` is supplied.
    @ViewBuilder
    var folderRow: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(folderName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                ItemCount(count: children.count)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(folderURL.path)
        .modifier(RemoveFolderMenu(folderURL: folderURL, onRemoveFolder: onRemoveFolder))
    }

    // MARK: Expanded children — RecentList's idiom, one indent deeper.

    @ViewBuilder
    var childRows: some View {
        if children.isEmpty {
            Text("No matching files")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.leading, 28)   // align under where child names sit
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(children, id: \.self) { url in
                    Button {
                        onPickChild(url)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: childSystemImage)
                                .frame(width: 20)
                                .foregroundStyle(.tertiary)
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(url.path)
                    // Children are NOT MRU entries — no remove menu (a folder's
                    // contents aren't individually tracked).
                }
            }
        }
    }
}

/// Attaches the "Remove Folder" destructive context-menu when a removal callback
/// is supplied; a no-op modifier otherwise. Right-click (macOS) / long-press
/// (iOS) both surface `.contextMenu` — one modifier serves both platforms.
private struct RemoveFolderMenu: ViewModifier {
    let folderURL: URL
    let onRemoveFolder: ((URL) -> Void)?

    func body(content: Content) -> some View {
        if let onRemoveFolder {
            content.contextMenu {
                Button(role: .destructive) {
                    onRemoveFolder(folderURL)
                } label: {
                    Label("Remove Folder", systemImage: "trash")
                }
            }
        } else {
            content
        }
    }
}

// MARK: - FOLDERS sub-block (the N-folder presentation wrapper)

/// The "FOLDERS" sub-block inside a mode section's body — a collapsible
/// `SidebarSection` (header + chevron + trailing count) whose body is the stack
/// of `FolderBlock` disclosures (M13·P3). Settled design after the P3a canvas
/// pass:
///
/// - **One-expanded-at-a-time.** Opening a folder collapses its siblings; the
///   accordion is the only presentation (the `.independent` candidate lost and
///   was deleted, config and all). The collapse/expand is animated by the
///   parent keying `.snappy(duration: 0.22)` on the open-folder identity,
///   matching `SidebarView`'s page-accordion idiom.
/// - **Renders even with zero folders** — the header always shows; an empty
///   state shows a quiet hint pointing at the mode header's open button (which
///   adds folders now — smoke round 1 deleted the dedicated add button).
/// - **Counts everywhere** — the FOLDERS header carries the folder count; each
///   `FolderBlock` row carries its matching-child count.
///
/// **Composed look only (M13·P4).** This `View` form draws the FOLDERS block as
/// one self-contained `SidebarSection` — used by the *gallery* (and any future
/// non-pinned context). In the live sidebar, the section is flattened into the
/// pinning `LazyVStack`: `SourcesPanel` emits the FOLDERS header and each open
/// folder as their own `Section`s rather than nesting them here, so they pin
/// natively. The two share `FolderBlock` so the look stays one source of truth.
///
/// Like `FolderBlock`, this is fully data-driven for the gallery: it takes a
/// list of folders + callbacks; no `RecentFolders` reads.
struct FoldersBlock: View {
    /// One folder's worth of plain data for the wrapper to render.
    struct Folder: Identifiable {
        let url: URL
        let children: [URL]
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    let folders: [Folder]
    let childSystemImage: String
    /// Whether the whole FOLDERS sub-block is expanded (the section chevron).
    @Binding var isExpanded: Bool
    /// Which single folder's disclosure is open (one-expanded-at-a-time). `nil`
    /// when all folders are collapsed.
    @Binding var openFolder: URL?
    let onPickChild: (URL) -> Void
    /// Forget a folder from the MRU. `nil` in the gallery.
    var onRemoveFolder: ((URL) -> Void)?

    var body: some View {
        SidebarSection("FOLDERS", isExpanded: $isExpanded) {
            ItemCount(count: folders.count)
        } content: {
            if folders.isEmpty {
                FoldersBlockEmpty()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(folders) { folder in
                        FolderBlock(
                            folderName: folder.name,
                            folderURL: folder.url,
                            children: folder.children,
                            childSystemImage: childSystemImage,
                            isExpanded: binding(for: folder.url),
                            onPickChild: onPickChild,
                            onRemoveFolder: onRemoveFolder
                        )
                    }
                }
                // One-expanded accordion: animate the sibling collapse on the
                // open-folder identity, matching the sidebar's page accordion.
                .animation(.snappy(duration: 0.22), value: openFolder)
            }
        }
    }

    /// A per-folder expansion binding that enforces one-expanded-at-a-time on
    /// write: opening a folder sets `openFolder` to it (collapsing whatever was
    /// open); closing it clears `openFolder`.
    private func binding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { openFolder == url },
            set: { open in openFolder = open ? url : nil }
        )
    }
}

/// The quiet zero-folders hint shown under the FOLDERS header. Shared by the
/// composed + flattened forms. Points at the mode header's open button — smoke
/// round 1 deleted the dedicated add button, so that button (which now accepts a
/// file OR a folder) is how folders get added.
struct FoldersBlockEmpty: View {
    var body: some View {
        Text("Use the open button above to add a folder to browse here.")
            .font(.callout)
            .foregroundStyle(.tertiary)
    }
}

#if DEBUG
#Preview("FolderBlock · expanded") {
    @Previewable @State var expanded = true
    let folder = PreviewFixtures.sampleVideoFolders[0]
    FolderBlock(
        folderName: folder.name,
        folderURL: folder.url,
        children: folder.children,
        childSystemImage: "film",
        isExpanded: $expanded,
        onPickChild: { _ in }
    )
    .padding()
    .frame(width: 280)
}

#Preview("FolderBlock · empty") {
    @Previewable @State var expanded = true
    let folder = PreviewFixtures.sampleEmptyVideoFolder
    FolderBlock(
        folderName: folder.name,
        folderURL: folder.url,
        children: folder.children,
        childSystemImage: "film",
        isExpanded: $expanded,
        onPickChild: { _ in }
    )
    .padding()
    .frame(width: 280)
}
#endif
