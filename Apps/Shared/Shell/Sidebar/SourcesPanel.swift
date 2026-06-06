import SwiftUI

/// The file-source body of an active mode section (Playback / Image) — RECENT
/// over FOLDERS, each a collapsible sub-block, composed for ONE mode (M13·P3).
///
/// **Placement: FOLDERS below RECENT** (user call) — a freshly picked video/image
/// lands at the top of RECENT anyway, so RECENT is the hot zone; FOLDERS sits
/// underneath. Collapsing RECENT (it gets long) is the fast path to reach
/// FOLDERS.
///
/// **Two collapsible sub-blocks inside the section's 0.08 body zone.** Both are
/// `SidebarSection`s — the same design-language primitive the MODEL / DATASET
/// sections use — reused here so the sub-headers (header text + chevron +
/// trailing count) match the house look while reading as visually subordinate to
/// the accent-tinted section header above them. RECENT regains a functional
/// caption: the M9·P6·4 redesign dropped it as redundant, but this user call
/// brings it back as a collapse control (a header, not just a label).
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
/// model + security-scope handling at the shell layer.
struct SourcesPanel: View {
    // RECENT
    let recents: [URL]
    let recentSystemImage: String
    let onPickRecent: (URL) -> Void
    let recentEmptyHint: String

    // FOLDERS
    let folders: [FoldersBlock.Folder]
    let folderChildSystemImage: String
    let onAddFolder: () -> Void
    let onPickChild: (URL) -> Void
    /// Fired when a folder's disclosure opens, with that folder's URL — the
    /// shell re-enumerates its children (freshness) under the folder's scope.
    let onExpandFolder: (URL) -> Void

    @State private var recentExpanded = true
    @State private var foldersExpanded = true
    @State private var openFolder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SidebarSection("RECENT", isExpanded: $recentExpanded) {
                ItemCount(count: recents.count)
            } content: {
                RecentList(
                    recents: recents,
                    systemImage: recentSystemImage,
                    onPick: onPickRecent,
                    emptyHint: recentEmptyHint
                )
            }

            FoldersBlock(
                folders: folders,
                childSystemImage: folderChildSystemImage,
                isExpanded: $foldersExpanded,
                openFolder: openFolderBinding,
                onAddFolder: onAddFolder,
                onPickChild: onPickChild
            )
        }
    }

    /// Wraps the `openFolder` state so opening a folder also fires
    /// `onExpandFolder` (the re-enumeration trigger). Closing fires nothing.
    private var openFolderBinding: Binding<URL?> {
        Binding(
            get: { openFolder },
            set: { newValue in
                openFolder = newValue
                if let newValue { onExpandFolder(newValue) }
            }
        )
    }
}

#if DEBUG
#Preview("Sources · populated") {
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
    .padding()
    .frame(width: 280)
}

#Preview("Sources · empty FOLDERS") {
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
    .padding()
    .frame(width: 280)
}
#endif
