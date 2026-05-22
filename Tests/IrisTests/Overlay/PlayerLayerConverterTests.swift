import CoreGraphics
import Testing

@testable import Iris

/// Pure-math coverage of `PlayerLayerConverter`. Exercises the static
/// `convert(...)` helpers directly so the math is locked in M2 even
/// though end-to-end playback wiring lands in M3.
///
/// `PreviewLayerConverter` is deliberately not tested here — it requires a
/// real `AVCaptureVideoPreviewLayer` backed by an `AVCaptureSession`,
/// which belongs in M2 Phase 7's physical-device smoke.
@Suite("PlayerLayerConverter")
struct PlayerLayerConverterTests {

    // MARK: - Rect conversion

    @Test
    func identityCaseMapsFullNormalizedRectToFullVideoRect() {
        // videoRect at origin; normalized (0,0,1,1) → the full videoRect.
        let videoRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

        let converted = PlayerLayerConverter.convert(
            normalizedRect: unit,
            videoRect: videoRect
        )

        #expect(converted == videoRect)
    }

    @Test
    func bottomLeftNormalizedRectMapsToTopLeftViewRectAfterYFlip() {
        // Vision normalized (0, 0, 0.5, 0.5) is the bottom-left quadrant.
        // After Y-flip into top-left-origin view coords, it should land in
        // the *top-left* quadrant of the view (origin y = 0).
        let videoRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let bottomLeftQuadrant = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)

        let converted = PlayerLayerConverter.convert(
            normalizedRect: bottomLeftQuadrant,
            videoRect: videoRect
        )

        // y = 0 + (1 - 0 - 0.5) * 100 = 50  →  rect occupies y=[50, 100],
        // i.e. the bottom half of the view in top-left coords. That's the
        // expected outcome of mapping Vision's bottom-left quadrant.
        #expect(converted == CGRect(x: 0, y: 50, width: 50, height: 50))
    }

    @Test
    func topLeftNormalizedRectMapsToBottomLeftViewRectAfterYFlip() {
        // Sanity check on the flip direction: Vision normalized (0, 0.5,
        // 0.5, 0.5) is the top-left quadrant in Vision space — should land
        // in the top-left of the view in top-left-origin coords.
        let videoRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let topLeftQuadrant = CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)

        let converted = PlayerLayerConverter.convert(
            normalizedRect: topLeftQuadrant,
            videoRect: videoRect
        )

        // y = 0 + (1 - 0.5 - 0.5) * 100 = 0  →  rect at y=0, top of view.
        #expect(converted == CGRect(x: 0, y: 0, width: 50, height: 50))
    }

    @Test
    func letterboxedVideoRectOffsetsConvertedRectByVideoOrigin() {
        // 100×200 container with 16:9-shaped 100×56.25 letterbox area
        // centered vertically. videoRect captures that pillarbox/letterbox
        // origin; converted rect must sit *inside* the video area, not the
        // full container.
        let videoRect = CGRect(x: 0, y: 71.875, width: 100, height: 56.25)
        let center = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

        let converted = PlayerLayerConverter.convert(
            normalizedRect: center,
            videoRect: videoRect
        )

        // x: 0 + 0.25 * 100 = 25
        // y: 71.875 + (1 - 0.25 - 0.5) * 56.25 = 71.875 + 14.0625 = 85.9375
        // w: 0.5 * 100 = 50;  h: 0.5 * 56.25 = 28.125
        #expect(converted.origin.x == 25)
        #expect(abs(converted.origin.y - 85.9375) < 1e-6)
        #expect(converted.width == 50)
        #expect(abs(converted.height - 28.125) < 1e-6)
    }

    @Test
    func pillarboxedVideoRectScalesWidthAgainstVideoWidthNotContainer() {
        // 200×100 container with a 4:3-style 133.33×100 video centered
        // horizontally (pillarbox). Width must scale against the video's
        // 133.33, not the container's 200.
        let videoRect = CGRect(
            x: 33.333_333_333_333_336,
            y: 0,
            width: 133.333_333_333_333_34,
            height: 100
        )
        let fullWidthBand = CGRect(x: 0, y: 0.4, width: 1.0, height: 0.2)

        let converted = PlayerLayerConverter.convert(
            normalizedRect: fullWidthBand,
            videoRect: videoRect
        )

        // Full normalized width maps to the *video's* width, offset by the
        // video's x-origin (the pillarbox).
        #expect(abs(converted.origin.x - 33.333_333_333_333_336) < 1e-6)
        #expect(abs(converted.width - 133.333_333_333_333_34) < 1e-6)
        // Height: 0.2 * 100 = 20; y: 0 + (1 - 0.4 - 0.2) * 100 = 40
        #expect(abs(converted.origin.y - 40) < 1e-6)
        #expect(abs(converted.height - 20) < 1e-6)
    }

    // MARK: - Point conversion

    @Test
    func bottomLeftNormalizedPointMapsToBottomLeftOfVideoRectAfterYFlip() {
        // Vision (0, 0) — bottom-left of the source frame — lands at the
        // bottom-left of the on-screen video area in top-left-origin
        // view coords (max y of the video rect).
        let videoRect = CGRect(x: 10, y: 20, width: 100, height: 50)

        let converted = PlayerLayerConverter.convert(
            normalizedPoint: CGPoint(x: 0, y: 0),
            videoRect: videoRect
        )

        // x: 10 + 0 = 10;  y: 20 + (1 - 0) * 50 = 70 = videoRect.maxY
        #expect(converted == CGPoint(x: 10, y: 70))
    }

    @Test
    func topLeftNormalizedPointMapsToTopLeftOfVideoRectAfterYFlip() {
        // Vision (0, 1) — top-left of the source frame — lands at the
        // top-left of the on-screen video area in top-left-origin view
        // coords (videoRect.origin).
        let videoRect = CGRect(x: 10, y: 20, width: 100, height: 50)

        let converted = PlayerLayerConverter.convert(
            normalizedPoint: CGPoint(x: 0, y: 1),
            videoRect: videoRect
        )

        // x: 10 + 0 = 10;  y: 20 + (1 - 1) * 50 = 20 = videoRect.origin.y
        #expect(converted == CGPoint(x: 10, y: 20))
    }
}
