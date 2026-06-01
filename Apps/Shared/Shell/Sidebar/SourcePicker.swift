import SwiftUI

/// The "Open… button + `RECENT` list" pairing that Playback and Image both
/// present inside their expanded mode-section (M9·P6·3). Extracted from the old
/// `NavigationSection.expandedContent` so the duplicated arm lives in one place.
///
/// The open button is a modest, content-width bordered control (a utility
/// action, not the hero of the panel); `RecentList` follows as a spacing-6
/// sibling — exactly the layout the old playback/image arms produced.
struct SourcePicker: View {
    let openTitle: String
    let openSystemImage: String
    let onOpen: () -> Void
    let recents: [URL]
    let recentSystemImage: String
    let onPick: (URL) -> Void
    let emptyHint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onOpen) {
                Label(openTitle, systemImage: openSystemImage)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.bottom, 4)

            RecentList(
                recents: recents,
                systemImage: recentSystemImage,
                onPick: onPick,
                emptyHint: emptyHint
            )
        }
    }
}

#if DEBUG
#Preview("Populated") {
    SourcePicker(
        openTitle: "Open Video…",
        openSystemImage: "folder.badge.plus",
        onOpen: {},
        recents: PreviewFixtures.sampleVideoURLs,
        recentSystemImage: "play.rectangle",
        onPick: { _ in },
        emptyHint: "Use Open Video… to pick a clip."
    )
    .padding()
    .frame(width: 280)
}

#Preview("Empty") {
    SourcePicker(
        openTitle: "Open Video…",
        openSystemImage: "folder.badge.plus",
        onOpen: {},
        recents: [],
        recentSystemImage: "play.rectangle",
        onPick: { _ in },
        emptyHint: "Use Open Video… to pick a clip."
    )
    .padding()
    .frame(width: 280)
}
#endif
