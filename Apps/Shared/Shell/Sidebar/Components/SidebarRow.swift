import SwiftUI

/// The selectable navigation row — the design-language primitive for a tappable
/// sidebar entry. Renders the active/inactive treatment that was previously
/// inlined in `pageRow`: an accent-tinted rounded selection when active, a bare
/// label otherwise.
///
/// Disabled state is applied by the caller via `.disabled(_:)` (so a disabled
/// Capture row stays the caller's concern); the row itself takes no disabled
/// parameter.
struct SidebarRow: View {
    let title: String
    let systemImage: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("Active / inactive / disabled") {
    VStack(alignment: .leading, spacing: 4) {
        SidebarRow(title: "Playback", systemImage: "play.rectangle", isActive: true, action: {})
        SidebarRow(title: "Image", systemImage: "photo", isActive: false, action: {})
        SidebarRow(title: "Capture", systemImage: "camera", isActive: false, action: {})
            .disabled(true)
    }
    .padding()
    .frame(width: 280)
}
#endif
