import SwiftUI

/// Shared layout primitives for the active mode section's *flattened* anatomy
/// (M13·P4). To get native sequential header pinning, the active section's
/// header band, its RECENT / FOLDERS sub-headers, and each open folder's row
/// are emitted as sibling `Section`s inside one
/// `LazyVStack(pinnedViews: .sectionHeaders)` (see `SidebarView`). Splitting the
/// section into sibling rows means the look that `ModeSection`'s `activeSection`
/// drew as ONE composite — the 3-pt accent bar down the left edge, the 0.22
/// accent header band, the 0.08 body zone — has to be reconstructed per row so
/// the rows still read as one continuous banded section. These modifiers are
/// that single source of truth.
///
/// **Why the underlays matter.** Pinned headers scroll *over* the content
/// beneath them. A header carrying only a translucent `0.22`/`0.08` tint would
/// show the rows sliding through it. Each pinnable header therefore gets an
/// opaque sidebar-material underlay (`.bar`) *below* its tint, so a pinned
/// header reads as solid while preserving the accent/primary tint on top.
enum SidebarBand {
    /// The accent bar width, matching `ModeSection.activeSection`'s 3-pt rule.
    static let accentBarWidth: CGFloat = 3
    /// Header-band accent tint (matches `ModeSection`'s 0.22).
    static let headerTint = Color.accentColor.opacity(0.22)
    /// Body-zone tint (matches `ModeSection`'s 0.08).
    static let bodyTint = Color.primary.opacity(0.08)
}

extension View {
    /// Lay a 3-pt accent bar down the leading edge of a flattened section row so
    /// the bar reads continuous across the sibling `Section`s that make up one
    /// active mode section. Applied to every row (headers *and* content) that
    /// belongs to the active section.
    func sidebarAccentBar() -> some View {
        self.overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: SidebarBand.accentBarWidth)
        }
    }

    /// Background for a *pinnable* header: an opaque sidebar-material underlay so
    /// the header stays solid when pinned over scrolling content, with the
    /// supplied tint laid on top (the accent 0.22 for the mode band, the primary
    /// 0.08 for the RECENT/FOLDERS/folder sub-headers).
    func pinnedHeaderBackground(_ tint: Color) -> some View {
        self.background {
            ZStack {
                Rectangle().fill(.bar)
                tint
            }
        }
    }
}
