import SwiftUI

/// Positions `content` at `alignment` within the on-screen video display rect
/// (the aspect-fit letterboxed region) so overlays ride the image, not the
/// letterbox bars. Uses the same ``VideoGeometry`` authority the overlay draws
/// through — so a corner-aligned affordance (a bookmark, a badge) lands on the
/// video frame's corner exactly where `DetectionLayer` would place a box there.
///
/// ## Hit-testing
///
/// Only `content` is tappable. The clear box that locates the video rect is
/// `allowsHitTesting(false)`, and the wrapper itself adds no opaque surface, so
/// taps anywhere in the video area that miss `content` pass straight through to
/// whatever sits beneath (the player, the detection overlay's gesture targets,
/// etc.). This matters because the wrapper is typically attached as a
/// full-container `.overlay`.
///
/// ## Empty rect
///
/// Until the content size is known, `VideoGeometry.displayRect` is `.zero`
/// (presentation size not yet published, or a degenerate container). In that
/// case the view renders nothing — no zero-sized box, no stray content — and
/// re-evaluates once the geometry reader reports a non-empty rect.
public struct VideoRectAligned<Content: View>: View {

    /// Upright source-frame content size — the same value the demos pass to
    /// `VideoGeometry(contentSize:...)` when building the overlay converter
    /// (typically `PlaybackController.presentationSize`).
    public let contentSize: CGSize

    /// Corner / edge of the video display rect to pin `content` to.
    public let alignment: Alignment

    @ViewBuilder public let content: () -> Content

    public init(
        contentSize: CGSize,
        alignment: Alignment = .topTrailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.contentSize = contentSize
        self.alignment = alignment
        self.content = content
    }

    public var body: some View {
        GeometryReader { proxy in
            let rect = VideoGeometry(
                contentSize: contentSize,
                containerSize: proxy.size,
                contentMode: .aspectFit
            ).displayRect

            // Empty/degenerate geometry → render nothing (see doc comment).
            if !rect.isEmpty {
                // A non-hit-testing clear box laid exactly over the video
                // display rect, with `content` aligned to its corner as an
                // overlay. `allowsHitTesting(false)` on the clear box disables
                // ONLY the clear backing — the `.overlay` content (added after)
                // keeps its default hit-testing, so the affordance stays
                // tappable while every other point in the video area passes its
                // touches straight through. A single `content` instance, sized
                // and positioned onto the display rect.
                Color.clear
                    .allowsHitTesting(false)
                    .frame(width: rect.width, height: rect.height)
                    .overlay(alignment: alignment) { content() }
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }
}

#if DEBUG

/// Visual proof that `VideoRectAligned` pins its content to the **video image**
/// corner, not the container corner. The container (gray border) is wider than
/// the video's aspect, so aspect-fit pillarboxes the frame — leaving bars left
/// and right. A `FlagButton`-like circle aligned `.topTrailing` should sit at
/// the top-right of the *pillarboxed video rect* (well inside the right bar),
/// not jammed against the container's right edge.
#Preview("VideoRectAligned · topTrailing on pillarboxed video") {
    // 16:9 source content in a 4:3-ish container → side pillarbars.
    let contentSize = CGSize(width: 1280, height: 720)

    ZStack {
        // Container backdrop. The "video image" region is drawn from the same
        // VideoGeometry authority so the stand-in puck's placement is judged
        // against where the frame actually is.
        Color(white: 0.08)

        GeometryReader { proxy in
            let rect = VideoGeometry(
                contentSize: contentSize,
                containerSize: proxy.size,
                contentMode: .aspectFit
            ).displayRect
            // The video image region (a gradient stand-in for a real frame).
            LinearGradient(
                colors: [.orange, .pink, .indigo],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
        }

        // The thing under test: a 38pt material puck pinned to the video rect's
        // top-right corner. It should ride the gradient, clear of the bars.
        VideoRectAligned(contentSize: contentSize, alignment: .topTrailing) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(.regularMaterial, in: Circle())
                .padding(12)
        }
    }
    .frame(width: 420, height: 220)
    .border(Color.gray.opacity(0.6), width: 1)
    .padding()
}

#endif
