import CoreMedia
import SwiftUI

/// Thin built-in timeline strip drawing one tick per flagged frame, meant to
/// sit **behind** the stock scrubber `Slider` (as a `.background` / ZStack
/// underlay) so flagged positions are visible while scrubbing without
/// consuming a separate vertical row. Each tick is positioned to line up with
/// where the slider thumb would sit at that flag's fraction (see
/// ``thumbInset``). The ticks draw **taller than the slider track** so they
/// peek above and below the thumb and stay visible even where the thumb
/// overlaps them.
///
/// **Coarse secondary overview, not the source of truth.** The on-frame
/// bookmark (``FlagButton``) is the primary flag affordance; this rail is a
/// glanceable map of where the flags are while scrubbing. The ticks are not
/// individually tappable — jumping to a flag is the flagged-frames list's job.
///
/// Does **not** replace the slider — it underlays the same horizontal extent
/// (the demos align it to the slider's track insets). Reactive to
/// ``FlaggingModel/currentFlags``; an invalid / zero / non-finite duration
/// renders an empty strip rather than dividing by zero.
public struct FlagMarkerStrip: View {

    /// The flagging brain — read for `currentFlags` (reactive).
    @Bindable public var model: FlaggingModel

    /// Total asset duration, used to map each flag's PTS to an x-fraction.
    /// Pass the playback controller's `duration`. `.invalid` / `.zero`
    /// renders empty.
    public let duration: CMTime

    /// Overall strip height — the vertical extent the markers are laid out in
    /// and centered within. As a behind-the-slider underlay this should be a
    /// bit taller than the stock slider track so the ticks peek above/below
    /// the thumb. Default is sized for that role.
    public var height: CGFloat = 22

    /// Height of each individual tick. Defaults to the full strip ``height``
    /// so ticks span the whole strip; when the strip is taller than the track
    /// the ticks remain visible around the thumb.
    public var tickHeight: CGFloat?

    /// Thumb **radius** of the stock `Slider`, in points. The slider thumb's
    /// center travels an inset track `[R, width − R]` rather than the full
    /// `[0, width]`, so a naive `x = fraction · width` mapping drifts left of
    /// the thumb. Insetting tick positions by this radius (see
    /// ``xPosition(for:width:)``) lines the ticks up under the thumb. The
    /// stock thumb is platform-specific — the iOS knob (~27–28 pt) is larger
    /// than the macOS knob — so the default differs per platform.
    public var thumbInset: CGFloat = Self.defaultThumbInset

    /// Per-platform default thumb radius. iOS stock `Slider` thumb ≈ 27–28 pt
    /// ⇒ R ≈ 14; macOS slider knob ≈ 20–21 pt ⇒ R ≈ 10. Now that the strip is
    /// sized to the Slider's real track frame (via `Scrubber.trackUnderlay`),
    /// `thumbInset` is the only remaining variable in tick-under-thumb
    /// alignment; the macOS value is tuned to the measured knob radius.
    public static var defaultThumbInset: CGFloat {
        #if os(macOS)
        10
        #else
        14
        #endif
    }

    public init(
        model: FlaggingModel,
        duration: CMTime,
        height: CGFloat = 22,
        tickHeight: CGFloat? = nil,
        thumbInset: CGFloat = Self.defaultThumbInset
    ) {
        self.model = model
        self.duration = duration
        self.height = height
        self.tickHeight = tickHeight
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
                    }
                }
            }
            .frame(width: width, height: height)
        }
        .frame(height: height)
        // Underlay only — never intercept scrubber drags.
        .allowsHitTesting(false)
    }

    /// A single tick. A thin rounded capsule tinted with the accent color so
    /// it reads as a bookmark rail without competing with the slider thumb.
    /// Drawn at ``tickHeight`` (defaulting to the full strip ``height``) so it
    /// peeks above/below the slider thumb when used as a behind-slider underlay.
    private var marker: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 3, height: tickHeight ?? height)
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

/// **Alignment proof (favorite pattern).** Renders the SAME composition the
/// demos use — a `Scrubber` with the marker strip in its `trackUnderlay`
/// slot — so the strip is sized to the Slider's real track width (not a bare
/// Slider with mismatched padding). The `MockScrubberModel` is parked on the
/// FIRST preview flag's fraction (1.2 s / 10 s = 0.12). The tall ticks peek
/// above and below the slider track; the first tick should sit dead-center
/// under the slider thumb — so thumb-vs-tick alignment is checkable in the
/// Xcode canvas WITHOUT running the app. The flags land at 0.12 / 0.45 /
/// 0.78; the model here is parked on the 0.12 flag so its thumb should kiss
/// the first tick.
#Preview("FlagMarkerStrip · behind slider (alignment)") {
    let total = 10.0
    let (model, _) = FlaggingModel.previewModel()
    return Scrubber(
        model: MockScrubberModel(
            currentTime: CMTime(seconds: 1.2, preferredTimescale: 600),
            duration: CMTime(seconds: total, preferredTimescale: 600),
            state: .idle
        )
    ) {
        FlagMarkerStrip(
            model: model,
            duration: CMTime(seconds: total, preferredTimescale: 600)
        )
    }
    .frame(width: 360)
    .padding()
}

#endif
