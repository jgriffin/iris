import Testing

@testable import Iris

// MARK: - Schema round-trip

/// The hand-rolled `VisionRectanglesSettings.schema` is the
/// drift-prone seam (see the "Schema-published-by-detector duplicates
/// concrete knowledge" risk in `plans/features/M4.md`). These tests
/// pin the schema to the stored properties so any future addition or
/// rename without a matching schema update fails loudly here, not
/// silently in a generic UI.

@Test
func visionRectanglesSchemaEnumeratesEveryKnownKnob() {
    let schema = VisionRectanglesSettings.schema
    let keys = Set(schema.knobs.map(\.key))

    // Every Vision knob currently surfaced through the schema. `label`
    // is intentionally excluded (no UI surfaces it). `minimumConfidence`
    // is gone — M5 deleted it (Vision rectangles have no probabilistic
    // confidence).
    let expected: Set<String> = [
        "minimumAspectRatio",
        "maximumAspectRatio",
        "minimumSize",
        "maximumObservations",
        "quadratureToleranceDegrees",
    ]

    #expect(keys == expected, "Schema knobs drifted from settings: \(keys) vs \(expected)")
    #expect(schema.knobs.count == expected.count, "Duplicate knob keys?")
}

@Test
func visionRectanglesSchemaDefaultsMatchSettingsDefaults() {
    // `VisionRectanglesSettings()` builds with the documented defaults;
    // the schema should publish the same defaults so a generic UI
    // populated from the schema matches the detector's actual
    // starting state.
    let defaults = VisionRectanglesSettings()
    let schema = VisionRectanglesSettings.schema

    for knob in schema.knobs {
        switch knob.key {
        case "minimumAspectRatio":
            guard case .float(_, _, let d) = knob.kind else {
                Issue.record("minimumAspectRatio should be .float")
                continue
            }
            #expect(d == defaults.minimumAspectRatio)
        case "maximumAspectRatio":
            guard case .float(_, _, let d) = knob.kind else {
                Issue.record("maximumAspectRatio should be .float")
                continue
            }
            #expect(d == defaults.maximumAspectRatio)
        case "minimumSize":
            guard case .float(_, _, let d) = knob.kind else {
                Issue.record("minimumSize should be .float")
                continue
            }
            #expect(d == defaults.minimumSize)
        case "maximumObservations":
            guard case .int(_, _, let d) = knob.kind else {
                Issue.record("maximumObservations should be .int")
                continue
            }
            #expect(d == defaults.maximumObservations)
        case "quadratureToleranceDegrees":
            guard case .float(_, _, let d) = knob.kind else {
                Issue.record("quadratureToleranceDegrees should be .float")
                continue
            }
            #expect(d == defaults.quadratureToleranceDegrees)
        default:
            Issue.record("Unexpected knob key: \(knob.key)")
        }
    }
}

@Test
func visionRectanglesSchemaTiersAreWorstCasePerKnob() {
    // The schema's static tier is the *worst-case* — the channel must
    // assume it when it can't ask the detector. The four Vision
    // *request*-parameter knobs are `.detector` (widening them needs
    // re-inference). `quadratureToleranceDegrees` is the exception:
    // M5 made it a pure post-hoc corner-angle filter (Vision is queried
    // at a fixed permissive tolerance), so its worst case is `.filter`
    // — it never needs re-inference in either direction.
    let expectedTiers: [String: ChangeTier] = [
        "minimumAspectRatio": .detector,
        "maximumAspectRatio": .detector,
        "minimumSize": .detector,
        "maximumObservations": .detector,
        "quadratureToleranceDegrees": .filter,
    ]
    let schema = VisionRectanglesSettings.schema
    for knob in schema.knobs {
        #expect(
            knob.tier == expectedTiers[knob.key],
            "Knob \(knob.key) tier \(knob.tier) != expected \(String(describing: expectedTiers[knob.key]))"
        )
    }
}

@Test
func defaultSettingsMatchPreM4DetectorDefaults() {
    // Backwards-compat anchor: the convenience init's defaults are
    // load-bearing for every existing call site. If these drift,
    // existing tests break silently because they take the default
    // path.
    let s = VisionRectanglesSettings()
    #expect(s.minimumAspectRatio == 0.5)
    #expect(s.maximumAspectRatio == 0.5)
    #expect(s.minimumSize == 0.2)
    #expect(s.maximumObservations == 0)
    #expect(s.quadratureToleranceDegrees == 30.0)
    #expect(s.label == "rectangle")
}

// MARK: - SettingChange value-payload round-trip

@Test
func settingChangeBuildersProducePayloadVariantsMatchingTheBuilder() {
    let f = SettingChange.float(key: "k", from: 0.1, to: 0.9)
    #expect(f.oldValue == .float(0.1))
    #expect(f.newValue == .float(0.9))

    let i = SettingChange.int(key: "k", from: 1, to: 3)
    #expect(i.oldValue == .int(1))
    #expect(i.newValue == .int(3))

    let t = SettingChange.toggle(key: "k", from: false, to: true)
    #expect(t.oldValue == .toggle(false))
    #expect(t.newValue == .toggle(true))

    let m = SettingChange.multiSelect(key: "k", from: ["a"], to: ["a", "b"])
    #expect(m.oldValue == .multiSelect(["a"]))
    #expect(m.newValue == .multiSelect(["a", "b"]))
}

@Test
func applyResultTierStripsPayloads() {
    #expect(ApplyResult.view.tier == .view)
    #expect(ApplyResult.filter(transform: { $0 }).tier == .filter)
    #expect(ApplyResult.detector(rebuilt: nil).tier == .detector)
}
