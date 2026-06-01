import SwiftUI

/// The middle navigation block: the three page-rows (Playback / Image /
/// Capture) separated by horizontal rules. The active row renders selected and
/// expands inline to its `Open…` button + `RECENT` list (or "Live camera" for
/// Capture); inactive rows are bare tappable labels. The Capture row is disabled
/// where the platform has no camera.
///
/// NOTE: the `.animation(.snappy…, value: page)` and the surrounding
/// `ScrollView` + outer vertical padding stay in `SidebarView` (the assembler),
/// matching the original structure — this view emits just the rows + dividers so
/// it can sit inside the assembler's scroll content unchanged.
struct NavigationSection: View {
    @Binding var page: ShellPage
    let captureAvailable: Bool

    // Playback page.
    let recentVideos: [URL]
    let onOpenVideo: () -> Void
    let onPickVideo: (URL) -> Void

    // Image page.
    let recentImages: [URL]
    let onOpenImage: () -> Void
    let onPickImage: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(.playback)
            Divider().padding(.horizontal, 12)
            row(.image)
            Divider().padding(.horizontal, 12)
            row(.capture)
        }
    }

    /// One page-row: the selectable `SidebarRow` plus, when active, the inline
    /// expanded content. Reproduces the original `pageRow` skeleton exactly
    /// (the `VStack(spacing: 6)` wrapper, the outer 12/4 paddings, the disabled
    /// Capture treatment, and the expanded-content transition + paddings).
    @ViewBuilder
    private func row(_ rowPage: ShellPage) -> some View {
        let isActive = page == rowPage
        let disabled = rowPage == .capture && !captureAvailable

        VStack(alignment: .leading, spacing: 6) {
            SidebarRow(
                title: rowPage.title,
                systemImage: rowPage.systemImage,
                isActive: isActive
            ) {
                page = rowPage
            }
            .disabled(disabled)

            if isActive && !disabled {
                expandedContent(for: rowPage)
                    .padding(.leading, 28)
                    .padding(.trailing, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func expandedContent(for rowPage: ShellPage) -> some View {
        switch rowPage {
        case .playback:
            openButton(title: "Open Video…", systemImage: "folder.badge.plus", action: onOpenVideo)
            RecentList(
                recents: recentVideos,
                systemImage: "play.rectangle",
                onPick: onPickVideo,
                emptyHint: "Use Open Video… to pick a clip."
            )
        case .image:
            openButton(title: "Open Image…", systemImage: "photo.badge.plus", action: onOpenImage)
            RecentList(
                recents: recentImages,
                systemImage: "photo",
                onPick: onPickImage,
                emptyHint: "Use Open Image… to pick a still."
            )
        case .capture:
            // Capture has no Open… / RECENT — it's the live camera.
            Text("Live camera")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func openButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        // A modest, content-width bordered button — it's a utility action, not
        // the hero of the panel, so it shouldn't shout.
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.bottom, 4)
    }
}

#if DEBUG
#Preview("Playback active") {
    @Previewable @State var page: ShellPage = .playback
    ScrollView {
        NavigationSection(
            page: $page,
            captureAvailable: true,
            recentVideos: PreviewFixtures.sampleVideoURLs,
            onOpenVideo: {},
            onPickVideo: { _ in },
            recentImages: PreviewFixtures.sampleImageURLs,
            onOpenImage: {},
            onPickImage: { _ in }
        )
        .padding(.vertical, 8)
    }
    .frame(width: 280, height: 500)
}
#endif
