import CoreGraphics
import Testing

@testable import Iris

/// Coverage of the pure render-time overlay filter,
/// `[Detection].filtered(minConfidence:)` (M9·P3). The filter is the seam the
/// overlay (`DetectionLayer`) applies at draw time; testing it here exercises
/// the floor semantics without rendering a SwiftUI view.
@Suite("Detection confidence filter")
struct DetectionConfidenceFilterTests {

    /// Real `Detection` fixtures spanning the floor — no mocks. `det(_:)`
    /// stamps a box-only detection at a given confidence.
    private func det(_ confidence: Float, label: String = "x") -> Detection {
        Detection(
            boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
            label: label,
            confidence: confidence,
            sourceModelID: "fixture"
        )
    }

    @Test("floor 0 keeps everything (behavior-neutral default)")
    func zeroFloorKeepsAll() {
        let input = [det(0.0), det(0.1), det(0.5), det(1.0)]
        #expect(input.filtered(minConfidence: 0) == input)
    }

    @Test("keeps above/at, drops below — inclusive >= boundary")
    func aboveAtAndBelow() {
        let below = det(0.49)
        let at = det(0.50)
        let above = det(0.51)
        let result = [below, at, above].filtered(minConfidence: 0.50)
        // `at` (== floor) survives; `below` drops; `above` survives.
        #expect(result == [at, above])
    }

    @Test("Vision-rectangles case: confidence 1.0 survives any sub-1.0 floor")
    func visionRectanglesSurviveSubOneFloor() {
        let vision = det(1.0, label: "rect")
        for floor: Float in [0.0, 0.25, 0.5, 0.75, 0.99] {
            #expect([vision].filtered(minConfidence: floor) == [vision])
        }
    }

    @Test("a real-score detector feels the floor")
    func realScoresAreFiltered() {
        // e.g. a YOLO-style mix of scores against a 0.25 floor.
        let dets = [det(0.05), det(0.20), det(0.25), det(0.90)]
        let result = dets.filtered(minConfidence: 0.25)
        #expect(result == [det(0.25), det(0.90)])
    }

    @Test("filter is order-preserving")
    func orderPreserving() {
        let dets = [det(0.9, label: "a"), det(0.8, label: "b"), det(0.95, label: "c")]
        let result = dets.filtered(minConfidence: 0.5)
        #expect(result.map(\.label) == ["a", "b", "c"])
    }

    @Test("floor above all confidences drops everything")
    func floorAboveAllDropsEverything() {
        let dets = [det(0.1), det(0.5), det(0.99)]
        #expect(dets.filtered(minConfidence: 1.0).isEmpty)
    }
}
