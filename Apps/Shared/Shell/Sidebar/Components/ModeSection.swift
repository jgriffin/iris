import SwiftUI

/// A *selectable* sidebar section — the page-section primitive for Playback /
/// Image / Capture. The active (selected) section renders the M9·P6·4 design:
/// a square left accent bar, a header band on its own accent tint (a filled,
/// accent-leaning mode icon + title + an optional trailing "open source" icon
/// button), flowing into a fainter body that holds the section's content (the
/// recents list, or "Live camera" for Capture). Inactive sections collapse to a
/// plain, tappable row (outline icon + title, both `.secondary`).
///
/// Selection is an accordion keyed to `page`: tapping an inactive row sets
/// `selection = page`, activating this section and collapsing the others. A
/// disabled mode (e.g. Capture with no camera) never activates.
struct ModeSection<Content: View>: View {
    let page: ShellPage
    @Binding var selection: ShellPage
    var isEnabled: Bool = true
    /// The trailing "open a source" action shown on the active header (Playback /
    /// Image). `nil` for modes without a file source (Capture) — no button.
    var onOpen: (() -> Void)?
    /// The SF Symbol for that open button.
    var openSystemImage: String
    @ViewBuilder var content: () -> Content

    init(
        page: ShellPage,
        selection: Binding<ShellPage>,
        isEnabled: Bool = true,
        onOpen: (() -> Void)? = nil,
        openSystemImage: String = "plus",
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.page = page
        self._selection = selection
        self.isEnabled = isEnabled
        self.onOpen = onOpen
        self.openSystemImage = openSystemImage
        self.content = content
    }

    private var isActive: Bool { selection == page && isEnabled }

    var body: some View {
        if isActive {
            activeSection
        } else {
            inactiveRow
        }
    }

    // MARK: Inactive — a plain, tappable row.

    private var inactiveRow: some View {
        Button { selection = page } label: {
            HStack(spacing: 8) {
                Image(systemName: page.systemImage)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(page.title)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.leading, 13)
            .padding(.trailing, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    // MARK: Active — accent bar + header band + body.

    private var activeSection: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
                headerBand
                content()
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.08))
            }
        }
        .transition(.opacity)
    }

    private var headerBand: some View {
        HStack(spacing: 8) {
            Image(systemName: page.activeSystemImage)
                .frame(width: 20)
                .foregroundStyle(Color.accentColor)
            Text(page.title)
                .fontWeight(.semibold)
            Spacer(minLength: 0)
            if let onOpen {
                Button(action: onOpen) {
                    Image(systemName: openSystemImage)
                        .font(.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open")
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.22))
    }
}

#if DEBUG
#Preview("Active · Playback") {
    @Previewable @State var page: ShellPage = .playback
    ModeSection(page: .playback, selection: $page, onOpen: {}, openSystemImage: "folder.badge.plus") {
        RecentList(
            recents: PreviewFixtures.sampleVideoURLs,
            systemImage: "film",
            onPick: { _ in },
            emptyHint: "Use Open Video… to pick a clip."
        )
    }
    .frame(width: 280)
}

#Preview("Inactive · Image") {
    @Previewable @State var page: ShellPage = .playback
    ModeSection(page: .image, selection: $page, onOpen: {}, openSystemImage: "photo.badge.plus") {
        RecentList(
            recents: PreviewFixtures.sampleImageURLs,
            systemImage: "photo",
            onPick: { _ in },
            emptyHint: "Use Open Image… to pick a still."
        )
    }
    .frame(width: 280)
}

#Preview("Disabled · Capture") {
    @Previewable @State var page: ShellPage = .playback
    ModeSection(page: .capture, selection: $page, isEnabled: false) {
        Text("Live camera").font(.caption).foregroundStyle(.secondary)
    }
    .frame(width: 280)
}
#endif
