import Testing

@testable import Iris

// MARK: - Test goal
//
// Per the 2026-05-24 "Detector capability model" decision: each
// detector declares a `DetectorCapabilities` descriptor that is the
// single source of truth for tuning UI / overlay / inspector. These
// tests pin the *rectangles* descriptor — the M5 motivating example —
// so the honest verdicts (confidence = none, geometry = quad+box, no
// confidence knob) can't silently regress.

private let rectangles = VisionRectanglesDetector()

// MARK: - Confidence semantics

@Test
func rectanglesDeclareNoConfidence() {
    // The whole point of M5: `RectangleObservation.confidence` is a
    // constant 1.0, not a probability. The descriptor must say `.none`
    // so the overlay draws no confidence chip and the inspector shows
    // `—`.
    #expect(rectangles.capabilities.confidence == .none)
}

@Test
func rectanglesDoNotMasqueradeAsProbabilistic() {
    // Belt-and-suspenders: explicitly assert it is *not* probabilistic
    // / perElement / a derived scalar. Catches an accidental
    // re-introduction of fabricated certainty.
    switch rectangles.capabilities.confidence {
    case .none:
        break  // expected
    case .probabilistic, .perElement, .derivedScalar:
        Issue.record("Rectangles must not claim meaningful confidence")
    }
}

// MARK: - Geometry kinds

@Test
func rectanglesDeclareQuadAndBoxGeometry() {
    // RectangleObservation carries four oriented corners (quad) plus
    // their axis-aligned hull (box). Both are real, both declared.
    #expect(rectangles.capabilities.geometryKinds == [.quad, .box])
}

@Test
func rectanglesDoNotClaimUnsupportedGeometry() {
    let kinds = rectangles.capabilities.geometryKinds
    #expect(!kinds.contains(.mask))
    #expect(!kinds.contains(.heatmap))
    #expect(!kinds.contains(.contour))
    #expect(!kinds.contains(.labelOnly))
    #expect(!kinds.contains(.scalar))
}

// MARK: - Tunable knobs (must exclude confidence)

@Test
func rectanglesTunableKnobsReuseTheSettingsSchema() {
    // The descriptor must not invent a parallel knob list — it reuses
    // `VisionRectanglesSettings.schema` verbatim so there's one source
    // of truth. Compare key sets.
    let descriptorKeys = Set(rectangles.capabilities.tunableKnobs.knobs.map(\.key))
    let schemaKeys = Set(VisionRectanglesSettings.schema.knobs.map(\.key))
    #expect(descriptorKeys == schemaKeys)
}

// NOTE: `rectanglesTunableKnobsExcludeConfidence` (asserting
// `minimumConfidence` is gone from the knob set) lands with the
// rectangles rework commit, where the schema edit that removes the
// knob makes it true. Adding it here would fail until that lands.

// MARK: - Introspectable fields

@Test
func rectanglesIntrospectableFieldsCoverActualPayload() {
    // The field list is the single source of truth for the Wave 2
    // filter UI and the P4 inspector. Rectangles carry a bounding box,
    // a label, and four corner keypoints — exactly those three fields.
    let fields = rectangles.capabilities.introspectableFields
    let keys = fields.map(\.key)
    #expect(keys == ["boundingBox", "label", "corners"])

    // Each field points at the right place on `Detection`.
    let bySource = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.source) })
    #expect(bySource["boundingBox"] == .boundingBox)
    #expect(bySource["label"] == .label)
    #expect(bySource["corners"] == .keypoints)

    let byKind = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.valueKind) })
    #expect(byKind["boundingBox"] == .boundingBox)
    #expect(byKind["label"] == .label)
    #expect(byKind["corners"] == .keypoints)
}

@Test
func rectanglesIntrospectableFieldsDoNotInventConfidence() {
    // Honesty check: a `.none`-confidence detector must not list a
    // confidence field for the inspector to render.
    let sources = rectangles.capabilities.introspectableFields.map(\.source)
    #expect(!sources.contains(.confidence))
}

// MARK: - Value semantics

@Test
func capabilitiesAreEquatable() {
    // `DetectorCapabilities` is a value type; two reads of the same
    // detector's descriptor compare equal. Underpins cache/inspector
    // diffing later.
    #expect(rectangles.capabilities == VisionRectanglesDetector().capabilities)
}
