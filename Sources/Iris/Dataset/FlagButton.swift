import SwiftUI

/// Built-in bookmark affordance for the current playback frame, styled as an
/// **on-frame overlay** rather than a control-row button. A bookmark glyph on
/// a circular `.regularMaterial` backing — `bookmark.fill` + accent tint when
/// the playhead sits on a flagged frame, hollow `bookmark` otherwise. A tap
/// flags / unflags the current frame via
/// ``FlaggingModel/toggleCurrent(reason:note:)``.
///
/// **Why a material backing.** This floats over arbitrary live video, so it
/// borrows the same legibility trick the detection labels use: a
/// `.regularMaterial` puck reads over bright or busy frame content without a
/// hard-coded color. The circle is ~38 pt with a ≥44 pt tap target via
/// `contentShape`, so it stays comfortable on touch while reading small on the
/// frame.
///
/// Disabled (dimmed) when there is no active asset or no current PTS —
/// flagging needs a complete `(asset, pts)` address. App owns placement (M4
/// doctrine): the demos attach this as a top-trailing overlay on the playback
/// `ZStack` so it floats over the video image, not the letterbox bars.
public struct FlagButton: View {

    /// The flagging brain. `@Bindable` so SwiftUI tracks the `@Observable`
    /// reads (`asset`, and the `isCurrentFlagged()` lookup through the store)
    /// and re-renders the icon when the current frame's flag state changes.
    @Bindable public var model: FlaggingModel

    /// Diameter of the circular material backing. ~38 pt reads small over the
    /// frame while the `contentShape` below lifts the tap target to ≥44 pt.
    private let diameter: CGFloat = 38

    public init(model: FlaggingModel) {
        self.model = model
    }

    public var body: some View {
        let flagged = model.isCurrentFlagged()
        Button {
            model.toggleCurrent()
        } label: {
            Image(systemName: flagged ? "bookmark.fill" : "bookmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(flagged ? Color.accentColor : .primary)
                .frame(width: diameter, height: diameter)
                .background(.regularMaterial, in: Circle())
                // Lift the tap target to a comfortable ≥44 pt while keeping
                // the visible puck at `diameter`.
                .contentShape(Circle().size(width: 44, height: 44))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(flagged ? "Unflag this frame" : "Flag this frame")
    }

    /// Enabled only with a complete frame address: an asset *and* a current
    /// PTS. `currentFlags` being readable doesn't imply a live playhead, so
    /// the model exposes the toggle's own guard via `isCurrentFlagged`'s
    /// preconditions — here we re-check `asset` and lean on the model's
    /// no-op guard for a missing PTS.
    private var isEnabled: Bool {
        model.asset != nil
    }
}

#if DEBUG

/// A stand-in "frame" so the material backing's legibility over real content
/// is visible in the canvas — the whole point of the restyle.
private struct PreviewFrameBackdrop<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        LinearGradient(
            colors: [.orange, .pink, .indigo],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .frame(width: 320, height: 200)
        .overlay(alignment: .topTrailing) {
            content.padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}

#Preview("FlagButton · flagged (over frame)") {
    let flags = FrameFlag.previewFlags()
    // Park the playhead exactly on the first flag so it reads as flagged.
    let source = MockFlaggingSource(currentPTS: flags[0].ref.pts)
    let (model, _) = FlaggingModel.previewModel(flags: flags, source: source)
    return PreviewFrameBackdrop { FlagButton(model: model) }
}

#Preview("FlagButton · unflagged (over frame)") {
    let flags = FrameFlag.previewFlags()
    // Playhead between flags → hollow bookmark.
    let source = MockFlaggingSource(currentPTS: .init(seconds: 2.5, preferredTimescale: 600))
    let (model, _) = FlaggingModel.previewModel(flags: flags, source: source)
    return PreviewFrameBackdrop { FlagButton(model: model) }
}

#Preview("FlagButton · disabled (no asset)") {
    let (model, _) = FlaggingModel.previewModel(flags: [], source: MockFlaggingSource(currentPTS: nil))
    model.clearAsset()
    return PreviewFrameBackdrop { FlagButton(model: model) }
}

#endif
