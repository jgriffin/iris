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
            ModeInactiveRow(page: page, isEnabled: isEnabled) { selection = page }
        }
    }

    // MARK: Active — accent bar + header band + body (composed form).
    //
    // Used by the gallery + previews. The LIVE sidebar does not use this; it
    // flattens the header band and the body's sub-blocks into the pinning
    // `LazyVStack` (see `SidebarView`), reusing `ModeHeaderBand` so the band
    // look stays one source of truth.

    private var activeSection: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: SidebarBand.accentBarWidth)
            VStack(alignment: .leading, spacing: 0) {
                ModeHeaderBand(page: page, onOpen: onOpen, openSystemImage: openSystemImage)
                    .background(SidebarBand.headerTint)
                content()
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SidebarBand.bodyTint)
            }
        }
        .transition(.opacity)
    }
}

/// The inactive (collapsed) mode row — a plain, tappable label. Extracted from
/// `ModeSection` (M13·P4) so the live sidebar can emit it as a bare, non-pinned
/// row in the scroll `LazyVStack` while the active section's pieces flatten into
/// pinnable `Section`s alongside it.
struct ModeInactiveRow: View {
    let page: ShellPage
    var isEnabled: Bool = true
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
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
}

/// The active mode section's accent header band — the filled mode icon + title +
/// optional trailing "open source" button on the 0.22 accent tint. Extracted
/// (M13·P4) so it can serve as the *pinned* `Section` header of the flattened
/// active section in the live sidebar AND the composed `ModeSection` form for
/// the gallery. The 3-pt accent bar + opaque pinned underlay are applied by the
/// caller (the live sidebar adds them; the composed `activeSection` draws the
/// bar itself and needs no opaque underlay).
struct ModeHeaderBand: View {
    let page: ShellPage
    var onOpen: (() -> Void)?
    var openSystemImage: String = "plus"

    var body: some View {
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
