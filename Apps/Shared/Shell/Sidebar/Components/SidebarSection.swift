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

/// The shared section-header style: the all-caps `MODEL` / `RECENT` / `DATASET`
/// label, plus an optional trailing accessory and an optional disclosure
/// chevron. Centralizes the label look that was previously copy-pasted.
struct SidebarSectionHeader<Accessory: View>: View {
    let title: String
    var isExpanded: Binding<Bool>?
    @ViewBuilder var accessory: () -> Accessory

    init(
        _ title: String,
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.isExpanded = isExpanded
        self.accessory = accessory
    }

    var body: some View {
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
}

/// The no-accessory header — matches the bare `Text` label sections used to
/// render inline (e.g. the `RECENT` list header), but routed through the shared
/// style so the look stays in one place.
extension SidebarSectionHeader where Accessory == EmptyView {
    init(_ title: String, isExpanded: Binding<Bool>? = nil) {
        self.init(title, isExpanded: isExpanded, accessory: { EmptyView() })
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
#endif
