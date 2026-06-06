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
/// **Plain data in, callbacks out — no state lookups.** The block takes the
/// folder name/URL, the already-enumerated `children`, an external expansion
/// `Binding`, and tap callbacks. It never reads `RecentFolders`, never calls
/// `folderListing` — that wiring lives in the parent (`SourcesPanel` →
/// `IrisShell`). This keeps it fully preview-drivable (the gallery feeds it
/// fixture URLs that need not exist on disk) and keeps one-expanded-at-a-time
/// possible: the parent owns the expansion state and collapses siblings.
struct FolderBlock: View {
    let folderName: String
    /// The folder's own URL — used only for the header tooltip (full path).
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

    private var folderRow: some View {
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
    }

    // MARK: Expanded children — RecentList's idiom, one indent deeper.

    @ViewBuilder
    private var childRows: some View {
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
                }
            }
        }
    }
}

// MARK: - FOLDERS sub-block (the N-folder presentation wrapper)

/// The "FOLDERS" sub-block inside a mode section's body — a collapsible
/// `SidebarSection` (header + chevron + trailing count + add-folder button)
/// whose body is the stack of `FolderBlock` disclosures (M13·P3). Settled
/// design after the P3a canvas pass:
///
/// - **One-expanded-at-a-time.** Opening a folder collapses its siblings; the
///   accordion is the only presentation (the `.independent` candidate lost and
///   was deleted, config and all). The collapse/expand is animated by the
///   parent keying `.snappy(duration: 0.22)` on the open-folder identity,
///   matching `SidebarView`'s page-accordion idiom.
/// - **Renders even with zero folders** — header + add button always show, so
///   the first folder can be added; an empty state shows a quiet hint.
/// - **Counts everywhere** — the FOLDERS header carries the folder count; each
///   `FolderBlock` row carries its matching-child count.
///
/// Like `FolderBlock`, this is fully data-driven for the gallery: it takes a
/// list of folders + callbacks; no `RecentFolders` reads. The live wiring
/// (`SourcesPanel`) feeds it the real folders MRU and the enumerate-on-expand
/// child listing.
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
    /// Present the add-folder picker for this mode (`folder.badge.plus`).
    let onAddFolder: () -> Void
    let onPickChild: (URL) -> Void

    var body: some View {
        SidebarSection("FOLDERS", isExpanded: $isExpanded) {
            HStack(spacing: 10) {
                ItemCount(count: folders.count)
                Button(action: onAddFolder) {
                    Image(systemName: "folder.badge.plus")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add a folder")
            }
        } content: {
            if folders.isEmpty {
                Text("Add a folder to browse its contents here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(folders) { folder in
                        FolderBlock(
                            folderName: folder.name,
                            folderURL: folder.url,
                            children: folder.children,
                            childSystemImage: childSystemImage,
                            isExpanded: binding(for: folder.url),
                            onPickChild: onPickChild
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
