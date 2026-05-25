import CoreGraphics
import Testing

@testable import Iris

// MARK: - Test goal
//
// M5 reclassifies `quadratureToleranceDegrees` from a Vision request
// parameter to a pure post-hoc corner-angle filter computed from the
// four corner keypoints Vision returns. These tests exercise the angle
// math directly with synthetic `Detection`s of known geometry — no
// dependence on Vision for the unit test of the predicate. A separate
// fixture test (VisionRectanglesDetectorFixtureTests) covers that the
// real clip still detects under the permissive-request change.

// MARK: - Helpers

/// Build a rectangle `Detection` carrying `corners` as keypoints in
/// `topLeft, topRight, bottomRight, bottomLeft` order, with a bounding
/// box equal to the corners' axis-aligned hull. Confidence is a constant
/// 1.0 — the honest Vision-rectangles value.
private func rectDetection(corners: [CGPoint]) -> Detection {
    let xs = corners.map(\.x)
    let ys = corners.map(\.y)
    let minX = xs.min() ?? 0
    let maxX = xs.max() ?? 0
    let minY = ys.min() ?? 0
    let maxY = ys.max() ?? 0
    let names = ["topLeft", "topRight", "bottomRight", "bottomLeft"]
    let kps = zip(names, corners).map {
        Detection.Keypoint(name: $0.0, position: $0.1, confidence: 1.0)
    }
    return Detection(
        boundingBox: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
        label: "rectangle",
        confidence: 1.0,
        keypoints: kps,
        sourceModelID: "vision.rectangles"
    )
}

/// A near-perfect axis-aligned square (all corners 90°).
private let perfectSquare = rectDetection(corners: [
    CGPoint(x: 0.2, y: 0.8),  // TL
    CGPoint(x: 0.8, y: 0.8),  // TR
    CGPoint(x: 0.8, y: 0.2),  // BR
    CGPoint(x: 0.2, y: 0.2),  // BL
])

/// A visibly skewed parallelogram: the top edge is sheared right by 0.2,
/// pushing the two side corners well off 90°.
private let skewedQuad = rectDetection(corners: [
    CGPoint(x: 0.4, y: 0.8),  // TL (sheared right)
    CGPoint(x: 1.0, y: 0.8),  // TR (sheared right)
    CGPoint(x: 0.8, y: 0.2),  // BR
    CGPoint(x: 0.2, y: 0.2),  // BL
])

// MARK: - interiorAngleDegrees

@Test
func interiorAngleOfRightAngleIs90() {
    // vertex at origin, rays along +x and +y → 90°.
    let angle = VisionRectanglesDetector.interiorAngleDegrees(
        prev: CGPoint(x: 1, y: 0),
        vertex: CGPoint(x: 0, y: 0),
        next: CGPoint(x: 0, y: 1)
    )
    #expect(angle != nil)
    #expect(abs((angle ?? 0) - 90.0) < 1e-6)
}

@Test
func interiorAngleOfStraightLineIs180() {
    let angle = VisionRectanglesDetector.interiorAngleDegrees(
        prev: CGPoint(x: -1, y: 0),
        vertex: CGPoint(x: 0, y: 0),
        next: CGPoint(x: 1, y: 0)
    )
    #expect(angle != nil)
    #expect(abs((angle ?? 0) - 180.0) < 1e-6)
}

@Test
func interiorAngleDegenerateEdgeReturnsNil() {
    // Zero-length ray to `next` → undefined angle.
    let angle = VisionRectanglesDetector.interiorAngleDegrees(
        prev: CGPoint(x: 1, y: 0),
        vertex: CGPoint(x: 0, y: 0),
        next: CGPoint(x: 0, y: 0)
    )
    #expect(angle == nil)
}

// MARK: - maximumCornerAngleDeviation

@Test
func perfectSquareHasZeroMaxDeviation() {
    let corners = (perfectSquare.keypoints ?? []).map(\.position)
    let dev = VisionRectanglesDetector.maximumCornerAngleDeviation(corners: corners)
    #expect(dev != nil)
    #expect((dev ?? 99) < 1e-6)
}

@Test
func skewedQuadHasLargeMaxDeviation() {
    let corners = (skewedQuad.keypoints ?? []).map(\.position)
    let dev = VisionRectanglesDetector.maximumCornerAngleDeviation(corners: corners)
    #expect(dev != nil)
    // The shear pushes at least one corner well beyond 10° off square.
    #expect((dev ?? 0) > 10.0)
}

@Test
func wrongCornerCountReturnsNil() {
    let dev = VisionRectanglesDetector.maximumCornerAngleDeviation(
        corners: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1)]
    )
    #expect(dev == nil)
}

// MARK: - quadratureAnglePredicate (the tunable knob's behavior)

@Test
func nearPerfectSquarePassesAtTightTolerance() {
    // A near-perfect square must survive a *tight* tolerance.
    let predicate = VisionRectanglesDetector.quadratureAnglePredicate(toleranceDegrees: 2.0)
    #expect(predicate(perfectSquare))
}

@Test
func skewedQuadRejectedAtTightTolerance() {
    // The same skewed quad that passes a wide tolerance must be dropped
    // at a tight one — the knob actually does something now.
    let tight = VisionRectanglesDetector.quadratureAnglePredicate(toleranceDegrees: 2.0)
    #expect(!tight(skewedQuad))
}

@Test
func skewedQuadAcceptedAtWideTolerance() {
    // At a permissive tolerance the same skewed quad is kept — symmetry:
    // loosening the knob re-admits it, with no re-inference.
    let wide = VisionRectanglesDetector.quadratureAnglePredicate(toleranceDegrees: 45.0)
    #expect(wide(skewedQuad))
}

@Test
func detectionWithoutFourCornersIsKept() {
    // A detection lacking the four corner keypoints can't be measured;
    // the filter abstains (keeps it) rather than dropping a shape it
    // can't judge.
    let noKeypoints = Detection(
        boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.2),
        label: "rectangle",
        confidence: 1.0,
        sourceModelID: "vision.rectangles"
    )
    let predicate = VisionRectanglesDetector.quadratureAnglePredicate(toleranceDegrees: 1.0)
    #expect(predicate(noKeypoints))
}

// MARK: - End-to-end through transform(for:)

@Test
func transformDropsSkewedQuadAtTightToleranceKeepsSquare() {
    // The full `transform(for:)` (aspect + size + quadrature + relabel)
    // at a tight tolerance keeps the square, drops the skewed quad.
    // Both boxes are square-hulled here, so widen the aspect window so
    // only the quadrature predicate decides the outcome.
    let settings = VisionRectanglesSettings(
        minimumAspectRatio: 0.0,
        maximumAspectRatio: 1.0,
        minimumSize: 0.0,
        quadratureToleranceDegrees: 3.0
    )
    let transform = VisionRectanglesDetector.transform(for: settings)
    let out = transform([perfectSquare, skewedQuad])
    #expect(out.count == 1)
    #expect(out.first == perfectSquare)
}

@Test
func transformKeepsBothAtWideTolerance() {
    let settings = VisionRectanglesSettings(
        minimumAspectRatio: 0.0,
        maximumAspectRatio: 1.0,
        minimumSize: 0.0,
        quadratureToleranceDegrees: 45.0
    )
    let transform = VisionRectanglesDetector.transform(for: settings)
    let out = transform([perfectSquare, skewedQuad])
    #expect(out.count == 2)
}
