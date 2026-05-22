import CoreGraphics
import SwiftUI
import Testing

@testable import Iris

/// Construction-level coverage for `OverlayStyle`. The struct is plain
/// configuration — `Color`, closures, and a couple of `CGFloat`s — so the
/// meaningful tests are: defaults construct, the `labelFormat` closure runs
/// against a synthetic `Detection`, and the `strokeColor` lookup exits.
/// Rendering-level visual checks live in `DetectionLayer`'s `#Preview` cases
/// and the co-located `box-rendering.html` reference.
@Suite("OverlayStyle")
struct OverlayStyleTests {

    @Test
    func defaultConstructsCleanly() {
        let style = OverlayStyle.default
        #expect(style.strokeWidth == 1.5)
        // Smoke: every default field is reachable.
        _ = style.labelTextColor
        _ = style.labelBackgroundColor
        _ = style.labelFont
    }

    @Test
    func labelFormatComposesLabelAndConfidence() {
        let style = OverlayStyle.default
        let detection = Detection(
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4),
            label: "face",
            confidence: 0.87,
            sourceModelID: "overlay-style-tests"
        )
        let formatted = style.labelFormat(detection)
        #expect(formatted.contains("face"))
        // Confidence is rendered as an integer percentage.
        #expect(formatted.contains("87"))
    }

    @Test
    func labelFormatSuppressesEmptyLabels() {
        let style = OverlayStyle.default
        let detection = Detection(
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4),
            label: "",
            confidence: 0.5,
            sourceModelID: "overlay-style-tests"
        )
        // Empty-label detections come back as `""` so `DetectionLayer`'s
        // draw pass skips the label backplate for them.
        #expect(style.labelFormat(detection).isEmpty)
    }

    @Test
    func strokeColorClosureFires() {
        let style = OverlayStyle.default
        // Smoke: invoke the closure for an arbitrary label; we just want
        // confirmation that the lookup returns *something* without trapping.
        _ = style.color(for: "face")
        _ = style.strokeColor("ball")
    }

    @Test
    func customStyleOverridesPerClassColor() {
        let style = OverlayStyle(
            strokeColor: { label in
                label == "face" ? .red : .gray
            }
        )
        #expect(style.color(for: "face") == Color.red)
        #expect(style.color(for: "ball") == Color.gray)
    }
}
