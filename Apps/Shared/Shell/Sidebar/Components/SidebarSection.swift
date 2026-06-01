import SwiftUI

/// A labeled section container — the design-language primitive every sidebar
/// section is built from. Content-agnostic: it owns only the header look
/// (the all-caps `.caption.weight(.semibold)` `.secondary` label), an optional
/// trailing accessory, and optional disclosure collapsibility. The body is
/// supplied by the caller.
///
/// **Collapsibility.** When `isExpanded` is `nil` (the current behavior of every
/// existing section) there is no chevron and the content always renders — so
/// nothing changes visually today. When a binding is supplied the header gains a
/// leading-rotating disclosure chevron (a `.plain` button) and the content is
/// shown only while expanded.
struct SidebarSection<Accessory: View, Content: View>: View {
    let title: String
    var isExpanded: Binding<Bool>?
    /// Vertical gap between the header and the content (and between content
    /// siblings). Defaults to 8 — the MODEL section's spacing; DATASET passes 6
    /// to preserve its tighter original strip layout.
    var spacing: CGFloat
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(
        _ title: String,
        isExpanded: Binding<Bool>? = nil,
        spacing: CGFloat = 8,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.isExpanded = isExpanded
        self.spacing = spacing
        self.accessory = accessory
        self.content = content
    }

    private var expanded: Bool { isExpanded?.wrappedValue ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            SidebarSectionHeader(title, isExpanded: isExpanded, accessory: accessory)

            if expanded {
                content()
            }
        }
    }
}

/// The common case: a section with no trailing accessory.
extension SidebarSection where Accessory == EmptyView {
    init(
        _ title: String,
        isExpanded: Binding<Bool>? = nil,
        spacing: CGFloat = 8,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title, isExpanded: isExpanded, spacing: spacing, accessory: { EmptyView() }, content: content)
    }
}

/// The shared section-header style. Two looks live under one roof so the
/// header treatment is centralized:
///
/// - `.label` — the all-caps `MODEL` / `RECENT` / `DATASET` text
///   (`.caption.weight(.semibold)`, `.secondary`), plus an optional trailing
///   accessory and an optional disclosure chevron. The plain-section default.
/// - `.mode(systemImage:isActive:)` — the *selectable* treatment (icon + title
///   + accent-tinted active selection) lifted verbatim from the old
///   `SidebarRow`, used by `ModeSection` for the Playback / Image / Capture
///   page-sections.
///
/// The `.label` initializers below keep the existing call sites
/// (`MODEL` / `DATASET` / `RECENT`) working unchanged.
struct SidebarSectionHeader<Accessory: View>: View {
    /// Which of the two header looks to render.
    enum Style {
        /// The all-caps text label (with optional accessory + chevron).
        case label
        /// The selectable mode treatment: an SF Symbol leading the title, with
        /// an accent-tinted rounded selection when `isActive`.
        case mode(systemImage: String, isActive: Bool)
    }

    let title: String
    var style: Style
    var isExpanded: Binding<Bool>?
    @ViewBuilder var accessory: () -> Accessory

    init(
        _ title: String,
        style: Style = .label,
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.style = style
        self.isExpanded = isExpanded
        self.accessory = accessory
    }

    var body: some View {
        switch style {
        case .label:
            labelHeader
        case let .mode(systemImage, isActive):
            modeHeader(systemImage: systemImage, isActive: isActive)
        }
    }

    /// The all-caps label header (unchanged from the original look).
    private var labelHeader: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            accessory()
            if let isExpanded {
                Button {
                    withAnimation { isExpanded.wrappedValue.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The selectable mode header — copied modifier-for-modifier from the old
    /// `SidebarRow.body` so a `ModeSection` header renders identically to a row.
    private func modeHeader(systemImage: String, isActive: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 20)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            Text(title)
                .fontWeight(isActive ? .semibold : .regular)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .foregroundStyle(isActive ? Color.primary : Color.secondary)
        // Active mode = a subtle accent-tinted rounded selection
        // (the native-sidebar idiom), replacing the old accent dot.
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
            }
        }
    }
}

/// The no-accessory header — matches the bare `Text` label sections used to
/// render inline (e.g. the `RECENT` list header), but routed through the shared
/// style so the look stays in one place. Also the entry point for the `.mode`
/// style, which never carries an accessory.
extension SidebarSectionHeader where Accessory == EmptyView {
    init(_ title: String, style: Style = .label, isExpanded: Binding<Bool>? = nil) {
        self.init(title, style: style, isExpanded: isExpanded, accessory: { EmptyView() })
    }
}

#if DEBUG
#Preview("Static section") {
    SidebarSection("MODEL") {
        Text("Some content")
            .font(.body)
        Text("More content")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding()
    .frame(width: 280)
}

#Preview("Collapsible · expanded") {
    @Previewable @State var expanded = true
    SidebarSection("DETAILS", isExpanded: $expanded) {
        Text("Visible when expanded")
            .font(.body)
    }
    .padding()
    .frame(width: 280)
}

#Preview("Collapsible · collapsed") {
    @Previewable @State var expanded = false
    SidebarSection("DETAILS", isExpanded: $expanded) {
        Text("Hidden when collapsed")
            .font(.body)
    }
    .padding()
    .frame(width: 280)
}

#Preview("Header · both styles") {
    VStack(alignment: .leading, spacing: 12) {
        // The plain-label style (MODEL / DATASET / RECENT).
        SidebarSectionHeader("MODEL")

        Divider()

        // The selectable mode style (Playback / Image / Capture), active +
        // inactive side by side.
        SidebarSectionHeader("Playback", style: .mode(systemImage: "play.rectangle", isActive: true))
        SidebarSectionHeader("Image", style: .mode(systemImage: "photo", isActive: false))
    }
    .padding()
    .frame(width: 280)
}
#endif
