import SwiftUI

/// One picked folder, drawn as a collapsible disclosure inside an active mode
/// section's body (M13·P3). The header is a folder row — folder glyph + name +
/// a chevron that rotates with the disclosure — and, when expanded, the folder's
/// matching children render as rows that *rhyme* with `RecentList`: same icon +
/// middle-truncated-name idiom, but visually subordinate (a deeper indent and a
/// quieter child glyph) so they read as living *inside* the folder rather than
/// as peers of the RECENT entries above them. An empty folder shows a quiet
/// "no matching files" caption in the same indented slot.
///
/// **Plain data in, callbacks out — no state lookups.** The block takes the
/// folder name/URL, the already-enumerated `children`, an external expansion
/// `Binding`, and tap callbacks. It never reads `RecentFolders`, never calls
/// `folderListing` — that wiring is the second half of P3. This keeps it fully
/// preview-drivable (the gallery feeds it fixture URLs that need not exist on
/// disk) and keeps the one-expanded-at-a-time presentation mode possible: the
/// parent owns the expansion state and can collapse siblings.
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
    /// presentation wrapper can enforce one-expanded-at-a-time.
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

    // MARK: Folder header row — glyph + name + disclosure chevron.

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
                Spacer(minLength: 0)
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

/// The presentation mode for a stack of `FolderBlock`s. The two candidates the
/// M13·P3 design pass is choosing between — settled in the canvas, then the
/// loser is deleted in the wiring half.
enum FolderPresentation {
    /// Each folder's disclosure is independent — open as many as you like.
    case independent
    /// Expanding one folder collapses the others (accordion).
    case oneExpanded
}

/// Lays out the picked folders as a "FOLDERS" sub-block inside a mode section
/// body, above or below the RECENT list (placement is the *other* P3 fork — it's
/// decided by where the caller drops this view, so the wrapper itself stays
/// placement-agnostic). It owns the per-folder expansion state and applies the
/// chosen `presentation` mode: `.independent` lets every folder toggle freely;
/// `.oneExpanded` collapses the rest whenever one opens.
///
/// Like `FolderBlock`, this is fully data-driven for the gallery: it takes a
/// list of fixture folders and renders them; no `RecentFolders` reads. The live
/// wiring pass replaces the fixture array with the real folders MRU.
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
    let presentation: FolderPresentation
    let onPickChild: (URL) -> Void

    /// Which folders are open. In `.oneExpanded` mode this is held to at most
    /// one entry; in `.independent` mode it grows freely.
    @State private var expanded: Set<URL> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FOLDERS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
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
        }
    }

    /// A per-folder expansion binding that enforces the presentation mode on
    /// write: `.oneExpanded` clears the set before inserting, so opening one
    /// collapses the rest.
    private func binding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(url) },
            set: { open in
                switch presentation {
                case .independent:
                    if open { expanded.insert(url) } else { expanded.remove(url) }
                case .oneExpanded:
                    expanded = open ? [url] : []
                }
            }
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
