import CoreGraphics
import Testing

@testable import Iris

// MARK: - Test goal
//
// Cover the core `TuningModel` write surface:
//   - `update(_:to:)` mutates `settings` via keyPath.
//   - The change is classified and `lastChange` / `lastApplyTier`
//     publish the result.
//   - The classifier dispatch goes through the wired detector.
//   - No-op writes short-circuit without ticking observation.
//
// Detector instance is a real `VisionRectanglesDetector` — its
// classifier table is the load-bearing piece exercised end-to-end
// here (the per-tier matrix is in `VisionRectanglesClassifierTests`).
//
// M5 deleted the `minimumConfidence` knob (Vision rectangles have no
// probabilistic confidence). These tests now drive `minimumAspectRatio`
// (filter on raise / detector on lower) and `quadratureToleranceDegrees`
// (the M5 post-hoc corner-angle filter, filter-tier both ways).

// MARK: - update mutates settings

@Test
@MainActor
func updateMutatesSettingsViaKeyPath() {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumAspectRatio: 0.2)
    )
    let model = TuningModel(detector: detector)

    model.update(\.minimumAspectRatio, to: 0.6)

    #expect(model.settings.minimumAspectRatio == 0.6)
}

@Test
@MainActor
func updateEmitsLastChangeWithKeyAndPayload() throws {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumAspectRatio: 0.2)
    )
    let model = TuningModel(detector: detector)

    model.update(\.minimumAspectRatio, to: 0.6)

    let change = try #require(model.lastChange)
    #expect(change.key == "minimumAspectRatio")
    #expect(change.oldValue == .float(0.2))
    #expect(change.newValue == .float(0.6))
}

@Test
@MainActor
func updatePublishesApplyTierFromClassifier() {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumAspectRatio: 0.2)
    )
    let model = TuningModel(detector: detector)

    // Raising minimumAspectRatio narrows the window → filter-tier.
    model.update(\.minimumAspectRatio, to: 0.6)
    #expect(model.lastApplyTier == .filter)
}

@Test
@MainActor
func updateDetectorTierSwapsDetector() throws {
    let initial = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumAspectRatio: 0.6)
    )
    let model = TuningModel(detector: initial)
    let priorRef = model.detector

    // Lowering minimumAspectRatio widens the window → detector-tier; the
    // classifier returns a rebuilt detector and the model swaps the ref.
    model.update(\.minimumAspectRatio, to: 0.2)

    #expect(model.lastApplyTier == .detector)
    let swapped = try #require(model.detector)
    #expect(swapped.settings.minimumAspectRatio == 0.2)
    // priorRef's settings still reflect the pre-change snapshot —
    // detectors are immutable post-construction.
    #expect(priorRef?.settings.minimumAspectRatio == 0.6)
}

// MARK: - No-op short-circuit

@Test
@MainActor
func updateWithIdenticalValueIsNoOp() {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumAspectRatio: 0.4)
    )
    let model = TuningModel(detector: detector)

    // First update establishes a baseline `lastChange`.
    model.update(\.minimumAspectRatio, to: 0.6)
    let baseline = model.lastChange

    // Identical write should not re-publish.
    model.update(\.minimumAspectRatio, to: 0.6)
    #expect(model.lastChange?.newValue == baseline?.newValue)
    #expect(model.lastChange?.oldValue == baseline?.oldValue)
}

// MARK: - Transform slot

@Test
@MainActor
func transformSlotIsAssignableAndReadable() {
    let detector = VisionRectanglesDetector()
    let model = TuningModel(detector: detector)

    #expect(model.transform == nil)

    let transform: @Sendable ([Detection]) -> [Detection] = { input in
        input.filter { $0.confidence >= 0.5 }
    }
    model.transform = transform

    #expect(model.transform != nil)
}

@Test
@MainActor
func filterTierUpdatePopulatesTransform() {
    // Every filter-tier `update` installs the detector-supplied
    // projection into `model.transform` so the overlay / pipeline pick
    // up the new settings without the consumer wiring a per-knob
    // predicate. Quadrature is filter-tier in both directions (M5).
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(quadratureToleranceDegrees: 30.0)
    )
    let model = TuningModel(detector: detector)
    #expect(model.transform == nil)

    model.update(\.quadratureToleranceDegrees, to: 10.0)

    #expect(model.lastApplyTier == .filter)
    #expect(model.transform != nil)
}

@Test
@MainActor
func filterTierTransformReflectsCurrentSettings() throws {
    // The installed transform behaves like the post-change settings — a
    // skewed quad that no longer passes the tightened quadrature
    // tolerance is dropped on the next overlay tick.
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(
            minimumAspectRatio: 0.0,
            maximumAspectRatio: 1.0,
            minimumSize: 0.0,
            quadratureToleranceDegrees: 30.0
        )
    )
    let model = TuningModel(detector: detector)
    model.update(\.quadratureToleranceDegrees, to: 3.0)

    // A near-perfect square (all corners 90°) survives; a sheared quad
    // (corners well off 90°) is dropped.
    let square = makeRect(corners: [
        CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.8, y: 0.8),
        CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.2, y: 0.2),
    ])
    let skewed = makeRect(corners: [
        CGPoint(x: 0.4, y: 0.8), CGPoint(x: 1.0, y: 0.8),
        CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.2, y: 0.2),
    ])

    let installed = try #require(model.transform)
    let projected = installed([square, skewed])
    #expect(projected.count == 1)
    #expect(projected.first == square)
}

@Test
@MainActor
func detectorTierUpdateClearsTransform() {
    // Detector-tier rebuild implicitly "starts fresh" — the rebuilt
    // detector hasn't yielded any transform context yet, so the prior
    // projection (derived from pre-rebuild settings) is cleared.
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumAspectRatio: 0.6)
    )
    let model = TuningModel(detector: detector)

    // First, install a transform via a filter-tier change (raise = filter).
    model.update(\.minimumAspectRatio, to: 0.8)
    #expect(model.transform != nil)

    // Then a detector-tier change (lower = detector) clears it.
    model.update(\.minimumAspectRatio, to: 0.1)
    #expect(model.lastApplyTier == .detector)
    #expect(model.transform == nil)
}

// MARK: - TuningRouter conformance

@Test
@MainActor
func currentDetectorErasesToAnyDetector() {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumAspectRatio: 0.3)
    )
    let model = TuningModel(detector: detector)

    let erased = model.currentDetector
    #expect(erased != nil)
    #expect(erased?.modelIdentifier == "vision.rectangles")
}

// MARK: - Settings-only init

@Test
@MainActor
func settingsOnlyInitOmitsDetector() {
    let model = TuningModel<VisionRectanglesDetector>(
        settings: VisionRectanglesSettings(minimumAspectRatio: 0.3)
    )

    #expect(model.detector == nil)
    #expect(model.currentDetector == nil)

    // Updating still mutates settings — there's just no classifier to
    // dispatch through, so `lastApplyTier` stays nil.
    model.update(\.minimumAspectRatio, to: 0.7)
    #expect(model.settings.minimumAspectRatio == 0.7)
    #expect(model.lastApplyTier == nil)
}

// MARK: - Helpers

/// Build a rectangle `Detection` with `corners` as keypoints in
/// `topLeft, topRight, bottomRight, bottomLeft` order and a bounding box
/// equal to their axis-aligned hull.
private func makeRect(corners: [CGPoint]) -> Detection {
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
