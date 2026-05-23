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

// MARK: - Filter slot

@Test
@MainActor
func filterSlotIsAssignableAndReadable() {
    let detector = VisionRectanglesDetector()
    let model = TuningModel(detector: detector)

    #expect(model.filter == nil)

    let predicate: @Sendable (Detection) -> Bool = { $0.confidence >= 0.5 }
    model.filter = predicate

    #expect(model.filter != nil)
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
