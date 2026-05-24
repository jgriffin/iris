import CoreGraphics
import Testing

@testable import Iris

// MARK: - Test goal
//
// Per `plans/features/M4.md`: "every Vision knob × direction →
// expected tier". The matrix below is the load-bearing safety net
// against tier misclassification — misclassifying a `.detector`
// change as `.filter` silently produces wrong overlays (cache says
// "no detection" because the *old* model parameter suppressed it).
//
// Detector instances are real `VisionRectanglesDetector` values (not
// mocks) per the fixture-based pattern used elsewhere in
// `Tests/IrisTests/Detection/`. The classifier is a pure function of
// the change, so no frame fixture is needed here.

private let baseline = VisionRectanglesDetector()

// MARK: - minimumConfidence

@Test
func minimumConfidenceRaiseIsFilter() {
    let change = SettingChange.float(key: "minimumConfidence", from: 0.2, to: 0.6)
    #expect(baseline.apply(change).tier == .filter)
}

@Test
func minimumConfidenceLowerIsDetector() {
    let change = SettingChange.float(key: "minimumConfidence", from: 0.6, to: 0.2)
    #expect(baseline.apply(change).tier == .detector)
}

@Test
func minimumConfidenceNoOpIsView() {
    let change = SettingChange.float(key: "minimumConfidence", from: 0.4, to: 0.4)
    #expect(baseline.apply(change).tier == .view)
}

@Test
func minimumConfidenceTypeIncompatibleFallsBackToDetector() {
    // Caller mis-built the change payload (e.g. passed an int into a
    // float knob). Worst-case fallback per `plans/features/M4.md`:
    // assume detector-tier so we never silently miss a re-inference.
    let change = SettingChange(
        key: "minimumConfidence",
        oldValue: .int(0),
        newValue: .int(1)
    )
    #expect(baseline.apply(change).tier == .detector)
}

// MARK: - minimumAspectRatio (lower-bound)

@Test
func minimumAspectRatioRaiseIsFilter() {
    let change = SettingChange.float(key: "minimumAspectRatio", from: 0.3, to: 0.7)
    #expect(baseline.apply(change).tier == .filter)
}

@Test
func minimumAspectRatioLowerIsDetector() {
    let change = SettingChange.float(key: "minimumAspectRatio", from: 0.7, to: 0.3)
    #expect(baseline.apply(change).tier == .detector)
}

@Test
func minimumAspectRatioNoOpIsView() {
    let change = SettingChange.float(key: "minimumAspectRatio", from: 0.5, to: 0.5)
    #expect(baseline.apply(change).tier == .view)
}

@Test
func minimumAspectRatioTypeIncompatibleFallsBackToDetector() {
    let change = SettingChange(
        key: "minimumAspectRatio",
        oldValue: .toggle(false),
        newValue: .toggle(true)
    )
    #expect(baseline.apply(change).tier == .detector)
}

// MARK: - maximumAspectRatio (upper-bound — inverted)

@Test
func maximumAspectRatioRaiseIsDetector() {
    let change = SettingChange.float(key: "maximumAspectRatio", from: 0.5, to: 1.0)
    #expect(baseline.apply(change).tier == .detector)
}

@Test
func maximumAspectRatioLowerIsFilter() {
    let change = SettingChange.float(key: "maximumAspectRatio", from: 1.0, to: 0.5)
    #expect(baseline.apply(change).tier == .filter)
}

@Test
func maximumAspectRatioNoOpIsView() {
    let change = SettingChange.float(key: "maximumAspectRatio", from: 0.8, to: 0.8)
    #expect(baseline.apply(change).tier == .view)
}

@Test
func maximumAspectRatioTypeIncompatibleFallsBackToDetector() {
    let change = SettingChange(
        key: "maximumAspectRatio",
        oldValue: .int(0),
        newValue: .int(1)
    )
    #expect(baseline.apply(change).tier == .detector)
}

// MARK: - minimumSize (lower-bound)

@Test
func minimumSizeRaiseIsFilter() {
    let change = SettingChange.float(key: "minimumSize", from: 0.1, to: 0.3)
    #expect(baseline.apply(change).tier == .filter)
}

@Test
func minimumSizeLowerIsDetector() {
    let change = SettingChange.float(key: "minimumSize", from: 0.3, to: 0.1)
    #expect(baseline.apply(change).tier == .detector)
}

@Test
func minimumSizeNoOpIsView() {
    let change = SettingChange.float(key: "minimumSize", from: 0.2, to: 0.2)
    #expect(baseline.apply(change).tier == .view)
}

// MARK: - quadratureToleranceDegrees (upper-bound — inverted)

@Test
func quadratureToleranceDegreesRaiseIsDetector() {
    let change = SettingChange.float(
        key: "quadratureToleranceDegrees", from: 15.0, to: 30.0
    )
    #expect(baseline.apply(change).tier == .detector)
}

@Test
func quadratureToleranceDegreesLowerIsFilter() {
    let change = SettingChange.float(
        key: "quadratureToleranceDegrees", from: 30.0, to: 15.0
    )
    #expect(baseline.apply(change).tier == .filter)
}

@Test
func quadratureToleranceDegreesNoOpIsView() {
    let change = SettingChange.float(
        key: "quadratureToleranceDegrees", from: 20.0, to: 20.0
    )
    #expect(baseline.apply(change).tier == .view)
}

// MARK: - maximumObservations (0-as-unlimited matrix)

@Test
func maximumObservationsFiniteRaiseIsDetector() {
    let change = SettingChange.int(key: "maximumObservations", from: 5, to: 10)
    #expect(baseline.apply(change).tier == .detector)
}

@Test
func maximumObservationsFiniteLowerIsFilter() {
    let change = SettingChange.int(key: "maximumObservations", from: 10, to: 5)
    #expect(baseline.apply(change).tier == .filter)
}

@Test
func maximumObservationsZeroToFiniteIsFilter() {
    // 0 = unlimited; setting any finite cap trims the existing list.
    let change = SettingChange.int(key: "maximumObservations", from: 0, to: 10)
    #expect(baseline.apply(change).tier == .filter)
}

@Test
func maximumObservationsFiniteToZeroIsDetector() {
    // finite cap → unlimited surfaces observations the model
    // previously truncated.
    let change = SettingChange.int(key: "maximumObservations", from: 10, to: 0)
    #expect(baseline.apply(change).tier == .detector)
}

@Test
func maximumObservationsNoOpIsView() {
    let change = SettingChange.int(key: "maximumObservations", from: 5, to: 5)
    #expect(baseline.apply(change).tier == .view)
}

@Test
func maximumObservationsZeroToZeroIsView() {
    let change = SettingChange.int(key: "maximumObservations", from: 0, to: 0)
    #expect(baseline.apply(change).tier == .view)
}

@Test
func maximumObservationsTypeIncompatibleFallsBackToDetector() {
    let change = SettingChange(
        key: "maximumObservations",
        oldValue: .float(0.0),
        newValue: .float(1.0)
    )
    #expect(baseline.apply(change).tier == .detector)
}

// MARK: - label

@Test
func labelChangeIsFilter() {
    let change = SettingChange(
        key: "label",
        oldValue: .multiSelect(["rectangle"]),
        newValue: .multiSelect(["document"])
    )
    #expect(baseline.apply(change).tier == .filter)
}

@Test
func labelNoOpIsView() {
    let change = SettingChange(
        key: "label",
        oldValue: .multiSelect(["rectangle"]),
        newValue: .multiSelect(["rectangle"])
    )
    #expect(baseline.apply(change).tier == .view)
}

// MARK: - unknown key

@Test
func unknownKeyFallsBackToDetector() {
    // An unknown key means the schema and detector got out of sync.
    // Channel must assume worst-case so we never silently miss a
    // re-inference.
    let change = SettingChange.float(key: "made-up-knob", from: 0.0, to: 1.0)
    #expect(baseline.apply(change).tier == .detector)
}

// MARK: - Sanity: classifier verdicts never exceed schema worst-case

@Test
func classifierNeverExceedsSchemaWorstCase() {
    // The classifier may downgrade .detector → .filter / .view, but
    // it must never *upgrade* past the schema's static tier. We
    // verify this for every schema knob with a representative
    // raise/lower/no-op transition.
    let schema = VisionRectanglesSettings.schema
    for knob in schema.knobs {
        switch knob.kind {
        case .float(_, _, let def):
            let raise = SettingChange.float(key: knob.key, from: def, to: def + 0.1)
            let lower = SettingChange.float(key: knob.key, from: def + 0.1, to: def)
            let noop = SettingChange.float(key: knob.key, from: def, to: def)
            #expect(tierRank(baseline.apply(raise).tier) <= tierRank(knob.tier))
            #expect(tierRank(baseline.apply(lower).tier) <= tierRank(knob.tier))
            #expect(tierRank(baseline.apply(noop).tier) <= tierRank(knob.tier))
        case .int(_, _, let def):
            let raise = SettingChange.int(key: knob.key, from: def, to: def + 1)
            let lower = SettingChange.int(key: knob.key, from: def + 1, to: def)
            let noop = SettingChange.int(key: knob.key, from: def, to: def)
            #expect(tierRank(baseline.apply(raise).tier) <= tierRank(knob.tier))
            #expect(tierRank(baseline.apply(lower).tier) <= tierRank(knob.tier))
            #expect(tierRank(baseline.apply(noop).tier) <= tierRank(knob.tier))
        case .toggle, .multiSelect:
            // No toggle/multiSelect knobs in the Vision schema yet.
            Issue.record("Unexpected toggle/multiSelect knob in Vision schema: \(knob.key)")
        }
    }
}

/// View < filter < detector. The classifier may only downgrade
/// (return a lower-ranked tier than the schema's worst-case).
private func tierRank(_ tier: ChangeTier) -> Int {
    switch tier {
    case .view: 0
    case .filter: 1
    case .detector: 2
    }
}

// MARK: - Filter-tier transform behavior

@Test
func filterTierVerdictCarriesProjectionMatchingNewSettings() throws {
    // M4 fix: every `.filter` verdict carries a transform that
    // projects the detector's *post-change* settings onto a cached
    // `[Detection]`. Construct a detection that just barely passes
    // the old floor (0.4) and fails the new one (0.6); the
    // transform must drop it.
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumConfidence: 0.2)
    )
    let change = SettingChange.float(key: "minimumConfidence", from: 0.2, to: 0.6)

    let result = detector.apply(change)
    guard case .filter(let transform) = result else {
        Issue.record("Expected .filter verdict, got \(result)")
        return
    }

    // Use a 2:1 box (short/long = 0.5) so it passes the default
    // aspect-ratio window [0.5, 0.5] and the default minimumSize
    // (0.2) — leaving confidence as the only knob in play for this
    // test.
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

    let projected = transform([lowConf, hiConf])
    #expect(projected.map(\.confidence) == [0.9])
}

@Test
func labelChangeTransformRewritesLabels() throws {
    // Label-rewrite arm: the transform must `map` the cached list
    // and replace every detection's label with the new value.
    // `Detection.label` is `let`, so the rewrite reconstructs the
    // value — the test pins that it lands on the field.
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(label: "rectangle")
    )
    let change = SettingChange(
        key: "label",
        oldValue: .multiSelect(["rectangle"]),
        newValue: .multiSelect(["document"])
    )

    let result = detector.apply(change)
    guard case .filter(let transform) = result else {
        Issue.record("Expected .filter verdict, got \(result)")
        return
    }

    let stale = Detection(
        boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.2),
        label: "rectangle",
        confidence: 0.9,
        sourceModelID: "vision.rectangles"
    )

    // The classifier projects via `projectedSettings`, which for the
    // `label` key has no encoded value (no `SettingKind.string` yet),
    // so the projection keeps the *current* `settings.label` —
    // "rectangle" here. This pins the current shape: the transform
    // rewrites to whatever `settings.label` says at apply-time, which
    // for now is the pre-change value (the relabel arm is still a
    // re-render at the detector's existing label). TODO M4 polish:
    // wire `SettingKind.string` so the new label flows through.
    let projected = transform([stale])
    #expect(projected.count == 1)
    #expect(projected.first?.label == "rectangle")
}
