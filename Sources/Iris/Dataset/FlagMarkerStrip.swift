import CoreMedia
import SwiftUI

/// Thin built-in timeline strip drawing one tick per flagged frame, meant to
/// sit directly **above** the stock scrubber `Slider` so flagged positions
/// are visible while scrubbing. Each tick is positioned to line up with where
/// the slider thumb would sit at that flag's fraction (see ``thumbInset``),
/// and is tappable to jump to that flag (``FlaggingModel/jump(to:)``).
///
/// **Coarse secondary overview, not the source of truth.** The on-frame
/// bookmark (``FlagButton``) is the primary flag affordance; this rail is a
/// glanceable map of where the flags are while scrubbing.
///
/// Does **not** replace the slider — it overlays the same horizontal extent
/// (the demos pad it to match the slider's track insets). Reactive to
/// ``FlaggingModel/currentFlags``; an invalid / zero / non-finite duration
/// renders an empty strip rather than dividing by zero.
public struct FlagMarkerStrip: View {

    /// The flagging brain — read for `currentFlags` (reactive) and to
    /// `jump(to:)` on a tick tap.
    @Bindable public var model: FlaggingModel

    /// Total asset duration, used to map each flag's PTS to an x-fraction.
    /// Pass the playback controller's `duration`. `.invalid` / `.zero`
    /// renders empty.
    public let duration: CMTime

    /// Strip height. Small by default — it's a marker rail, not a track.
    public var height: CGFloat = 14

    /// Thumb **radius** of the stock `Slider`, in points. The slider thumb's
    /// center travels an inset track `[R, width − R]` rather than the full
    /// `[0, width]`, so a naive `x = fraction · width` mapping drifts left of
    /// the thumb. Insetting tick positions by this radius (see
    /// ``xPosition(for:width:)``) lines the ticks up under the thumb. The
    /// stock thumb is platform-specific — the iOS knob (~27–28 pt) is larger
    /// than the macOS knob — so the default differs per platform.
    public var thumbInset: CGFloat = Self.defaultThumbInset

    /// Per-platform default thumb radius. iOS stock `Slider` thumb ≈ 27–28 pt
    /// ⇒ R ≈ 14; macOS slider knob is smaller ⇒ R ≈ 9.
    public static var defaultThumbInset: CGFloat {
        #if os(macOS)
        9
        #else
        14
        #endif
    }

    public init(
        model: FlaggingModel,
        duration: CMTime,
        height: CGFloat = 14,
        thumbInset: CGFloat = Self.defaultThumbInset
    ) {
        self.model = model
        self.duration = duration
        self.height = height
        self.thumbInset = thumbInset
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                ForEach(model.currentFlags, id: \.ref) { flag in
                    if let x = xPosition(for: flag, width: width) {
                        marker
                            .position(x: x, y: height / 2)
                            .onTapGesture { model.jump(to: flag) }
                    }
                }
            }
            .frame(width: width, height: height)
        }
        .frame(height: height)
    }

    /// A single tick. A thin rounded capsule tinted with the accent color so
    /// it reads as a bookmark rail without competing with the slider thumb.
    private var marker: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 3, height: height)
            // Widen the hit target beyond the 3-pt visual so taps land.
            .contentShape(Rectangle().size(width: 22, height: height))
    }

    /// Pixel x for `flag` across `width`, or `nil` when the duration is
    /// unusable (the strip renders empty). Maps onto the slider thumb's inset
    /// track `[R, width − R]` (`R` = ``thumbInset``) so a tick lands under the
    /// thumb at the same fraction: `x = R + fraction · (width − 2R)`. Clamps
    /// the fraction to `[0, 1]` so a flag whose PTS sits a hair past the
    /// reported duration still draws on-rail. Degrades to the full-width map
    /// if the strip is narrower than the thumb (`width ≤ 2R`).
    private func xPosition(for flag: FrameFlag, width: CGFloat) -> CGFloat? {
        guard duration.isValid, !duration.isIndefinite else { return nil }
        let total = CMTimeGetSeconds(duration)
        guard total.isFinite, total > 0, width > 0 else { return nil }
        let seconds = CMTimeGetSeconds(flag.ref.pts)
        guard seconds.isFinite else { return nil }
        let fraction = min(max(seconds / total, 0), 1)
        let track = width - 2 * thumbInset
        guard track > 0 else { return CGFloat(fraction) * width }
        return thumbInset + CGFloat(fraction) * track
    }
}

#if DEBUG

#Preview("FlagMarkerStrip · several flags") {
    let (model, _) = FlaggingModel.previewModel()
    return FlagMarkerStrip(
        model: model,
        duration: CMTime(seconds: 10, preferredTimescale: 600)
    )
    .padding(.horizontal, 16)
    .frame(width: 360)
    .padding()
}

#Preview("FlagMarkerStrip · empty (no duration)") {
    let (model, _) = FlaggingModel.previewModel()
    return FlagMarkerStrip(model: model, duration: .invalid)
        .padding(.horizontal, 16)
        .frame(width: 360)
        .padding()
}

/// **Alignment proof (favorite pattern).** Stacks the marker strip directly
/// above a real `Slider` at the same width and horizontal padding, with the
/// slider value parked on the FIRST preview flag's fraction (1.2 s / 10 s =
/// 0.12). The middle tick should sit dead-center under the slider thumb — so
/// thumb-vs-tick alignment (Change 2) is checkable in the Xcode canvas
/// WITHOUT running the app. The flags land at 0.12 / 0.45 / 0.78; the slider
/// here is parked on the 0.12 flag so its thumb should kiss the first tick.
#Preview("FlagMarkerStrip · thumb alignment") {
    // Park the slider on the first flag's fraction (1.2 s of 10 s).
    @Previewable @State var value = 0.12
    let total = 10.0
    let (model, _) = FlaggingModel.previewModel()
    return VStack(spacing: 0) {
        FlagMarkerStrip(
            model: model,
            duration: CMTime(seconds: total, preferredTimescale: 600)
        )
        Slider(value: $value, in: 0...1)
    }
    .padding(.horizontal, 16)
    .frame(width: 360)
    .padding()
}

#endif
