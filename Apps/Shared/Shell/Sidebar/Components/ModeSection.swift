import SwiftUI

/// A *selectable* sidebar section — the page-section primitive for Playback /
/// Image / Capture (M9·P6·3). It replaces the old "row-with-inline-expansion":
/// the section's header IS the selectable mode treatment (icon + title + active
/// accent tint, rendered by the shared `SidebarSectionHeader`'s `.mode` style),
/// and its expansion is driven by the page selection as an accordion —
/// expanded ⇔ `selection == page`. Tapping the header sets `selection = page`,
/// which collapses every other mode section.
///
/// When the mode is disabled (e.g. Capture with no camera), the header renders
/// `.disabled` and the section never expands.
///
/// This composes the old `SidebarRow` look (now the header) with the old
/// `expandedContent` skeleton verbatim, so a `ModeSection` renders identically
/// to a pre-refactor navigation row.
struct ModeSection<Content: View>: View {
    let page: ShellPage
    @Binding var selection: ShellPage
    var isEnabled: Bool = true
    @ViewBuilder var content: () -> Content

    init(
        page: ShellPage,
        selection: Binding<ShellPage>,
        isEnabled: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.page = page
        self._selection = selection
        self.isEnabled = isEnabled
        self.content = content
    }

    var body: some View {
        // Accordion: the section is expanded exactly when it's the selected
        // page and it's enabled — matching the old `isActive && !disabled`.
        let isExpanded = (selection == page) && isEnabled

        VStack(alignment: .leading, spacing: 6) {
            Button {
                selection = page
            } label: {
                SidebarSectionHeader(
                    page.title,
                    style: .mode(systemImage: page.systemImage, isActive: selection == page)
                )
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)

            if isExpanded {
                content()
                    .padding(.leading, 28)
                    .padding(.trailing, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

#if DEBUG
#Preview("Active · expanded") {
    @Previewable @State var page: ShellPage = .playback
    ModeSection(page: .playback, selection: $page) {
        SourcePicker(
            openTitle: "Open Video…",
            openSystemImage: "folder.badge.plus",
            onOpen: {},
            recents: PreviewFixtures.sampleVideoURLs,
            recentSystemImage: "play.rectangle",
            onPick: { _ in },
            emptyHint: "Use Open Video… to pick a clip."
        )
    }
    .frame(width: 280)
}

#Preview("Inactive · collapsed") {
    @Previewable @State var page: ShellPage = .playback
    ModeSection(page: .image, selection: $page) {
        SourcePicker(
            openTitle: "Open Image…",
            openSystemImage: "photo.badge.plus",
            onOpen: {},
            recents: PreviewFixtures.sampleImageURLs,
            recentSystemImage: "photo",
            onPick: { _ in },
            emptyHint: "Use Open Image… to pick a still."
        )
    }
    .frame(width: 280)
}

#Preview("Disabled") {
    @Previewable @State var page: ShellPage = .playback
    ModeSection(page: .capture, selection: $page, isEnabled: false) {
        Text("Live camera")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .frame(width: 280)
}
#endif
