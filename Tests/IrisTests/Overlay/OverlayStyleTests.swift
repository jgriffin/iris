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
    func labelFormatComposesLabelAndReadout() {
        let style = OverlayStyle.default
        let detection = Detection(
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4),
            label: "rectangle",
            confidence: 1.0,
            readout: Readout(label: "aspect", text: "1.42:1"),
            sourceModelID: "overlay-style-tests"
        )
        let formatted = style.labelFormat(detection)
        // Honest default: label + " · " + the detector's readout text.
        #expect(formatted == "rectangle · 1.42:1")
        // NEVER a fabricated confidence percentage.
        #expect(!formatted.contains("%"))
    }

    @Test
    func labelFormatShowsReadoutAloneForEmptyLabel() {
        let style = OverlayStyle.default
        let detection = Detection(
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4),
            label: "",
            confidence: 1.0,
            readout: Readout(label: "joints", text: "19 joints"),
            sourceModelID: "overlay-style-tests"
        )
        // Empty label + readout → just the readout text (no leading separator).
        #expect(style.labelFormat(detection) == "19 joints")
    }

    @Test
    func labelFormatShowsLabelOnlyWithoutReadout() {
        let style = OverlayStyle.default
        let detection = Detection(
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4),
            label: "face",
            confidence: 0.87,
            sourceModelID: "overlay-style-tests"
        )
        let formatted = style.labelFormat(detection)
        // No readout → just the label, and never a percentage.
        #expect(formatted == "face")
        #expect(!formatted.contains("%"))
        #expect(!formatted.contains("87"))
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
        // Empty-label, no-readout detections come back as `""` so
        // `DetectionLayer`'s draw pass skips the label backplate for them.
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
