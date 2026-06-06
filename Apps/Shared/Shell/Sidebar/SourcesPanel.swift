import SwiftUI

/// The file-source body of an active mode section (Playback / Image) — RECENT
/// over FOLDERS, each a collapsible sub-block, composed for ONE mode (M13·P3),
/// flattened into pinnable `Section`s (M13·P4).
///
/// **Placement: FOLDERS below RECENT** (user call) — a freshly picked video/image
/// lands at the top of RECENT anyway, so RECENT is the hot zone; FOLDERS sits
/// underneath. Collapsing RECENT (it gets long) is the fast path to reach
/// FOLDERS.
///
/// **Sequential native pinning (M13·P4).** Rather than nest RECENT + FOLDERS
/// inside one body `VStack`, this view emits them — and each *open* folder — as
/// sibling `Section`s via `@ViewBuilder` so the parent
/// `LazyVStack(pinnedViews: .sectionHeaders)` (in `SidebarView`) pins their
/// headers sequentially: RECENT header → FOLDERS header → open-folder row, each
/// deeper one replacing the shallower as you scroll, and (in `SidebarView`) the
/// mode header band above them all. The headers + content carry the active
/// section's anatomy themselves — the 3-pt accent bar (`.sidebarAccentBar()`)
/// down the leading edge, an opaque pinned underlay + 0.08 tint on headers
/// (`.pinnedHeaderBackground`), the 0.08 body tint on content — reconstructing
/// what the composed `ModeSection.activeSection` drew as one block.
///
/// **Ephemeral state, owned here, one instance per mode.** RECENT + FOLDERS both
/// default expanded; the per-folder accordion (`openFolder`) defaults to all
/// collapsed. No persistence this milestone. Each mode renders its own
/// `SourcesPanel`, so Playback and Image keep independent expansion state.
///
/// **Plain data in, callbacks out.** Folder *children* are supplied by the
/// caller already enumerated; this view never reads `RecentFolders` or calls
/// `folderListing`. Enumeration-on-expand lives in `IrisShell` (the
/// `onExpandFolder` callback fires when a folder opens), keeping the freshness
/// model + security-scope handling at the shell layer. Removal callbacks
/// (`onRemoveRecent` / `onRemoveFolder`) likewise just emit a URL; the shell
/// mutates the MRUs.
struct SourcesPanel: View {
    // RECENT
    let recents: [URL]
    let recentSystemImage: String
    let onPickRecent: (URL) -> Void
    let recentEmptyHint: String
    /// Forget a RECENT entry (context-menu). `nil` in the gallery.
    var onRemoveRecent: ((URL) -> Void)?

    // FOLDERS
    let folders: [FoldersBlock.Folder]
    let folderChildSystemImage: String
    let onAddFolder: () -> Void
    let onPickChild: (URL) -> Void
    /// Fired when a folder's disclosure opens, with that folder's URL — the
    /// shell re-enumerates its children (freshness) under the folder's scope.
    let onExpandFolder: (URL) -> Void
    /// Forget a folder from the MRU (context-menu; never touches disk). `nil` in
    /// the gallery.
    var onRemoveFolder: ((URL) -> Void)?

    @State private var recentExpanded = true
    @State private var foldersExpanded = true
    @State private var openFolder: URL?

    /// Emits the RECENT + FOLDERS (+ per-open-folder) `Section`s flattened so the
    /// parent `LazyVStack(pinnedViews: .sectionHeaders)` pins their headers. NOT
    /// wrapped in a container view of its own — the sections must be direct
    /// siblings of the parent LazyVStack's other rows to pin sequentially.
    @ViewBuilder
    var body: some View {
        // ── RECENT ───────────────────────────────────────────────────────
        Section {
            if recentExpanded {
                RecentList(
                    recents: recents,
                    systemImage: recentSystemImage,
                    onPick: onPickRecent,
                    emptyHint: recentEmptyHint,
                    onRemove: onRemoveRecent
                )
                .sourcesContent()
            }
        } header: {
            SourcesSubHeader("RECENT", isExpanded: $recentExpanded) {
                ItemCount(count: recents.count)
            }
        }

        // ── FOLDERS header ───────────────────────────────────────────────
        Section {
            if foldersExpanded, folders.isEmpty {
                FoldersBlockEmpty()
                    .sourcesContent()
            }
        } header: {
            SourcesSubHeader("FOLDERS", isExpanded: $foldersExpanded) {
                FoldersBlockHeaderAccessory(count: folders.count, onAddFolder: onAddFolder)
            }
        }

        // ── Each folder: its row is a pinnable Section header, its children
        //    the content. Only rendered while FOLDERS is expanded. ──────────
        if foldersExpanded {
            ForEach(folders) { folder in
                let block = FolderBlock(
                    folderName: folder.name,
                    folderURL: folder.url,
                    children: folder.children,
                    childSystemImage: folderChildSystemImage,
                    isExpanded: openFolderBinding(for: folder.url),
                    onPickChild: onPickChild,
                    onRemoveFolder: onRemoveFolder
                )
                Section {
                    if openFolder == folder.url {
                        block.childRows
                            .padding(.leading, 8)   // subordinate indent
                            .sourcesContent()
                    }
                } header: {
                    block.folderRow
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .sidebarAccentBar()
                        .pinnedHeaderBackground(SidebarBand.bodyTint)
                }
            }
            .animation(.snappy(duration: 0.22), value: openFolder)
        }
    }

    /// Per-folder expansion binding enforcing one-expanded-at-a-time, and firing
    /// `onExpandFolder` (the re-enumeration trigger) when a folder opens.
    private func openFolderBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { openFolder == url },
            set: { open in
                openFolder = open ? url : nil
                if open { onExpandFolder(url) }
            }
        )
    }
}

/// A sub-block header (RECENT / FOLDERS) styled as a flattened, pinnable section
/// header: the `SidebarSectionHeader` look inside the active section's anatomy —
/// accent bar + opaque pinned underlay + 0.08 tint + the band's 7/10 padding.
struct SourcesSubHeader<Accessory: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self._isExpanded = isExpanded
        self.accessory = accessory
    }

    var body: some View {
        SidebarSectionHeader(title, isExpanded: $isExpanded, accessory: accessory)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sidebarAccentBar()
            .pinnedHeaderBackground(SidebarBand.bodyTint)
    }
}

extension View {
    /// The active section's body-zone treatment for a content row in the
    /// flattened sidebar: 0.08 tint + the band's horizontal/vertical padding +
    /// the continued accent bar.
    func sourcesContent() -> some View {
        self
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SidebarBand.bodyTint)
            .sidebarAccentBar()
    }
}

#if DEBUG
// Previews render `SourcesPanel` inside a host that supplies the pinning
// `LazyVStack` + ScrollView, since the panel now emits bare `Section`s.
private struct SourcesPanelPreviewHost<Panel: View>: View {
    @ViewBuilder var panel: () -> Panel
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                panel()
            }
        }
    }
}

#Preview("Sources · populated") {
    SourcesPanelPreviewHost {
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
    .frame(width: 280, height: 600)
}

#Preview("Sources · empty FOLDERS") {
    SourcesPanelPreviewHost {
        SourcesPanel(
            recents: PreviewFixtures.sampleImageURLs,
            recentSystemImage: "photo",
            onPickRecent: { _ in },
            recentEmptyHint: "No recent images",
            folders: [],
            folderChildSystemImage: "photo",
            onAddFolder: {},
            onPickChild: { _ in },
            onExpandFolder: { _ in }
        )
    }
    .frame(width: 280, height: 600)
}
#endif
