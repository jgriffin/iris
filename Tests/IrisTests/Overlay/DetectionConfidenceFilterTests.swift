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

    // MARK: - Scalar form delegates to OverlayFilter

    @Test("scalar filtered(minConfidence:) equals the equivalent OverlayFilter")
    func scalarDelegatesToOverlayFilter() {
        let dets = [det(0.05), det(0.20), det(0.25), det(0.90)]
        for floor: Float in [0.0, 0.1, 0.25, 0.5, 1.0] {
            #expect(
                dets.filtered(minConfidence: floor)
                    == dets.filtered(by: OverlayFilter(globalMinConfidence: floor)),
                "scalar form must match OverlayFilter(globalMinConfidence: \(floor))"
            )
        }
    }
}

/// Coverage of the generalized render-time filter, `[Detection].filtered(by:)`
/// (M10·P1). Exercises hidden-label drops, per-label floor overrides (both
/// directions), the global fallback, the no-op passthrough, and order
/// preservation — the precedence the per-class tuning panel relies on.
@Suite("Overlay filter (per-class)")
struct OverlayFilterTests {

    private func det(_ confidence: Float, label: String) -> Detection {
        Detection(
            boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
            label: label,
            confidence: confidence,
            sourceModelID: "fixture"
        )
    }

    @Test("hidden label is dropped even when above its floor")
    func hiddenLabelDroppedAboveFloor() {
        let person = det(0.99, label: "person")
        let ball = det(0.99, label: "sports ball")
        let filter = OverlayFilter(
            globalMinConfidence: 0,
            perLabelMinConfidence: ["person": 0.1],  // would otherwise keep it
            hiddenLabels: ["person"]
        )
        // person is hidden outright; ball survives.
        #expect([person, ball].filtered(by: filter) == [ball])
    }

    @Test("per-label floor keeps a label the global floor would drop")
    func perLabelFloorLooserThanGlobal() {
        // Global floor 0.8 would drop a 0.3 ball; a per-label floor of 0.2
        // keeps it.
        let ball = det(0.3, label: "sports ball")
        let filter = OverlayFilter(
            globalMinConfidence: 0.8,
            perLabelMinConfidence: ["sports ball": 0.2]
        )
        #expect([ball].filtered(by: filter) == [ball])
    }

    @Test("per-label floor drops a label the global floor would keep")
    func perLabelFloorStricterThanGlobal() {
        // Global floor 0.1 would keep a 0.3 person; a per-label floor of 0.5
        // drops it.
        let person = det(0.3, label: "person")
        let filter = OverlayFilter(
            globalMinConfidence: 0.1,
            perLabelMinConfidence: ["person": 0.5]
        )
        #expect([person].filtered(by: filter).isEmpty)
    }

    @Test("global floor is the fallback for labels with no per-label entry")
    func globalFallbackForUnlistedLabels() {
        // "car" has no per-label entry → uses the global 0.5 floor.
        let carBelow = det(0.4, label: "car")
        let carAbove = det(0.6, label: "car")
        // "person" has its own floor and is unaffected by the global.
        let person = det(0.4, label: "person")
        let filter = OverlayFilter(
            globalMinConfidence: 0.5,
            perLabelMinConfidence: ["person": 0.2]
        )
        let result = [carBelow, person, carAbove].filtered(by: filter)
        // carBelow drops (below global), person survives (above its 0.2),
        // carAbove survives (above global).
        #expect(result == [person, carAbove])
    }

    @Test("empty/zero filter is an identity passthrough (order preserved)")
    func emptyFilterIsPassthrough() {
        let input = [
            det(0.0, label: "a"),
            det(0.4, label: "b"),
            det(1.0, label: "c"),
        ]
        let result = input.filtered(by: OverlayFilter())
        #expect(result == input)
        #expect(result.map(\.label) == ["a", "b", "c"])
    }

    @Test("order is preserved across a mixed filter")
    func orderPreservedWithMixedInput() {
        let dets = [
            det(0.9, label: "person"),     // kept (global)
            det(0.9, label: "dog"),        // hidden
            det(0.3, label: "sports ball"),// kept (per-label 0.2)
            det(0.1, label: "car"),        // dropped (global 0.5)
            det(0.9, label: "person"),     // kept (global)
        ]
        let filter = OverlayFilter(
            globalMinConfidence: 0.5,
            perLabelMinConfidence: ["sports ball": 0.2],
            hiddenLabels: ["dog"]
        )
        let result = dets.filtered(by: filter)
        #expect(result.map(\.label) == ["person", "sports ball", "person"])
    }
}
