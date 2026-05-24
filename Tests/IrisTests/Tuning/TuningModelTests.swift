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

// MARK: - update mutates settings

@Test
@MainActor
func updateMutatesSettingsViaKeyPath() {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumConfidence: 0.2)
    )
    let model = TuningModel(detector: detector)

    model.update(\.minimumConfidence, to: 0.6)

    #expect(model.settings.minimumConfidence == 0.6)
}

@Test
@MainActor
func updateEmitsLastChangeWithKeyAndPayload() throws {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumConfidence: 0.2)
    )
    let model = TuningModel(detector: detector)

    model.update(\.minimumConfidence, to: 0.6)

    let change = try #require(model.lastChange)
    #expect(change.key == "minimumConfidence")
    #expect(change.oldValue == .float(0.2))
    #expect(change.newValue == .float(0.6))
}

@Test
@MainActor
func updatePublishesApplyTierFromClassifier() {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumConfidence: 0.2)
    )
    let model = TuningModel(detector: detector)

    // Raising minimumConfidence is filter-tier per the classifier table.
    model.update(\.minimumConfidence, to: 0.6)
    #expect(model.lastApplyTier == .filter)
}

@Test
@MainActor
func updateDetectorTierSwapsDetector() throws {
    let initial = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumConfidence: 0.6)
    )
    let model = TuningModel(detector: initial)
    let priorRef = model.detector

    // Lowering minimumConfidence is detector-tier — the classifier
    // returns a rebuilt detector and the model swaps the reference.
    model.update(\.minimumConfidence, to: 0.2)

    #expect(model.lastApplyTier == .detector)
    // The reference itself changed (struct-copy semantics — the new
    // value is a distinct instance with the post-change settings).
    let swapped = try #require(model.detector)
    #expect(swapped.settings.minimumConfidence == 0.2)
    // priorRef's settings still reflect the pre-change snapshot —
    // detectors are immutable post-construction.
    #expect(priorRef?.settings.minimumConfidence == 0.6)
}

// MARK: - No-op short-circuit

@Test
@MainActor
func updateWithIdenticalValueIsNoOp() {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumConfidence: 0.4)
    )
    let model = TuningModel(detector: detector)

    // First update establishes a baseline `lastChange`.
    model.update(\.minimumConfidence, to: 0.6)
    let baseline = model.lastChange

    // Identical write should not re-publish.
    model.update(\.minimumConfidence, to: 0.6)
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
    // The M4 fix: every filter-tier `update` installs the
    // detector-supplied projection into `model.transform` so the
    // overlay / pipeline pick up the new settings without the
    // consumer having to wire a per-knob predicate.
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumConfidence: 0.2)
    )
    let model = TuningModel(detector: detector)
    #expect(model.transform == nil)

    // Raising minimumConfidence is filter-tier per the classifier.
    model.update(\.minimumConfidence, to: 0.6)

    #expect(model.lastApplyTier == .filter)
    #expect(model.transform != nil)
}

@Test
@MainActor
func filterTierTransformReflectsCurrentSettings() throws {
    // The installed transform should behave like the post-change
    // settings — a detection that no longer passes the new floor
    // should be dropped on the next overlay tick.
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumConfidence: 0.2)
    )
    let model = TuningModel(detector: detector)
    model.update(\.minimumConfidence, to: 0.6)

    // 2:1 box → short/long = 0.5 → passes the default aspect-ratio
    // window [0.5, 0.5] and the default minimumSize (0.2). Leaves
    // confidence as the only knob in play.
    let lowConf = Detection(
        boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.2),
        label: "rectangle",
        confidence: 0.4,
        sourceModelID: "vision.rectangles"
    )
    let hiConf = Detection(
        boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.4, height: 0.2),
        label: "rectangle",
        confidence: 0.9,
        sourceModelID: "vision.rectangles"
    )

    let installed = try #require(model.transform)
    let projected = installed([lowConf, hiConf])
    #expect(projected.map(\.confidence) == [0.9])
}

@Test
@MainActor
func detectorTierUpdateClearsTransform() {
    // Detector-tier rebuild implicitly "starts fresh" — the rebuilt
    // detector hasn't yielded any transform context yet, so the
    // prior projection (derived from pre-rebuild settings) is
    // cleared.
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumConfidence: 0.6)
    )
    let model = TuningModel(detector: detector)

    // First, install a transform via a filter-tier change.
    model.update(\.minimumConfidence, to: 0.8)
    #expect(model.transform != nil)

    // Then a detector-tier change should clear it.
    model.update(\.minimumConfidence, to: 0.1)
    #expect(model.lastApplyTier == .detector)
    #expect(model.transform == nil)
}

// MARK: - TuningRouter conformance

@Test
@MainActor
func currentDetectorErasesToAnyDetector() {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumConfidence: 0.3)
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
        settings: VisionRectanglesSettings(minimumConfidence: 0.3)
    )

    #expect(model.detector == nil)
    #expect(model.currentDetector == nil)

    // Updating still mutates settings — there's just no classifier to
    // dispatch through, so `lastApplyTier` stays nil.
    model.update(\.minimumConfidence, to: 0.7)
    #expect(model.settings.minimumConfidence == 0.7)
    #expect(model.lastApplyTier == nil)
}
