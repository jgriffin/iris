import CoreGraphics
import SwiftUI
import Testing

@testable import Iris

// MARK: - Test goal
//
// M5 Wave 2: the built-in tuning UI is *derived* from a detector's
// `DetectorCapabilities` + `SettingSchema`, not hand-authored. The
// load-bearing logic is the derivation mapping
// `CapabilityTuningProjection.controls(for:)` — these tests pin it
// without instantiating SwiftUI:
//
//   - confidence `.none`        → NO confidence control (rectangles).
//   - confidence `.perElement`  → a confidence control (mock pose).
//   - confidence `.probabilistic` with a minimumConfidence knob → slider.
//   - confidence `.derivedScalar(label:)` → a read-only labeled row.
//   - `.string` knob → text field; `.enum` knob → picker; etc.
//
// Plus the string-keyed mutation path the derived view binds through.

// MARK: - Capability profile builders

private func capabilities(
    confidence: DetectorCapabilities.ConfidenceSemantics,
    knobs: [SettingSchema.Knob]
) -> DetectorCapabilities {
    DetectorCapabilities(
        geometryKinds: [.box],
        confidence: confidence,
        tunableKnobs: SettingSchema(knobs: knobs),
        introspectableFields: []
    )
}

private let confidenceKnob = SettingSchema.Knob(
    key: "minimumConfidence",
    label: "Minimum confidence",
    kind: .float(range: 0.0...1.0, step: 0.01, default: 0.3),
    tier: .filter
)
private let aspectKnob = SettingSchema.Knob(
    key: "minimumAspectRatio",
    label: "Minimum aspect ratio",
    kind: .float(range: 0.0...1.0, step: 0.01, default: 0.5),
    tier: .detector
)
private let maxObsKnob = SettingSchema.Knob(
    key: "maximumObservations",
    label: "Maximum observations",
    kind: .int(range: 0...100, step: 1, default: 0),
    tier: .detector
)
private let handsKnob = SettingSchema.Knob(
    key: "detectsHands",
    label: "Detect hands",
    kind: .toggle(default: false),
    tier: .detector
)
private let modelEnumKnob = SettingSchema.Knob(
    key: "model",
    label: "Model",
    kind: .enum(options: ["fast", "accurate"], default: "fast"),
    tier: .detector
)
private let customWordKnob = SettingSchema.Knob(
    key: "customWord",
    label: "Custom word",
    kind: .string(default: ""),
    tier: .detector
)
private let classesKnob = SettingSchema.Knob(
    key: "classes",
    label: "Classes",
    kind: .multiSelect(options: ["person", "dog"], default: ["person"]),
    tier: .filter
)

// MARK: - Test-local mock detectors (for the View-level suppression tests)
//
// `CapabilityTuningView.hasVisibleControls` / `hidesConfidence` are tested
// against real `TunableDetector`s. Rectangles is reachable (`.none` confidence);
// these two cover `.perElement`-with-other-knobs and confidence-only profiles.

private struct MockMultiKnobSettings: DetectorSettings {
    var minimumConfidence: Float = 0.3
    var detectsHands: Bool = false
    var model: String = "fast"

    static var schema: SettingSchema {
        SettingSchema(knobs: [
            SettingSchema.Knob(
                key: "minimumConfidence",
                label: "Minimum joint confidence",
                kind: .float(range: 0.0...1.0, step: 0.01, default: 0.3),
                tier: .filter
            ),
            SettingSchema.Knob(
                key: "detectsHands",
                label: "Detect hands",
                kind: .toggle(default: false),
                tier: .detector
            ),
            SettingSchema.Knob(
                key: "model",
                label: "Model",
                kind: .enum(options: ["fast", "accurate"], default: "fast"),
                tier: .detector
            ),
        ])
    }

    func value(forKey key: String) -> SettingChange.Value? {
        switch key {
        case "minimumConfidence": return .float(minimumConfidence)
        case "detectsHands": return .toggle(detectsHands)
        case "model": return .string(model)
        default: return nil
        }
    }

    mutating func setValue(_ value: SettingChange.Value, forKey key: String) {
        switch (key, value) {
        case ("minimumConfidence", .float(let v)): minimumConfidence = v
        case ("detectsHands", .toggle(let v)): detectsHands = v
        case ("model", .string(let v)): model = v
        default: break
        }
    }
}

private struct MockPoseDetector: TunableDetector {
    typealias Settings = MockMultiKnobSettings
    let settings = MockMultiKnobSettings()
    let availability: DetectorAvailability = .available
    let modelIdentifier = "mock.pose"
    var capabilities: DetectorCapabilities {
        DetectorCapabilities(
            geometryKinds: [.keypoints],
            confidence: .perElement,
            tunableKnobs: MockMultiKnobSettings.schema,
            introspectableFields: []
        )
    }
    func prewarm() async {}
    func detect(in _: Frame) async throws -> [Detection] { [] }
    func apply(_: SettingChange) -> ApplyResult { .filter(transform: { $0 }) }
}

/// A detector whose ONLY tunable knob is the confidence floor — suppressing
/// confidence leaves it with zero visible controls.
private struct ConfidenceOnlySettings: DetectorSettings {
    var minimumConfidence: Float = 0.3
    static var schema: SettingSchema {
        SettingSchema(knobs: [
            SettingSchema.Knob(
                key: "minimumConfidence",
                label: "Minimum confidence",
                kind: .float(range: 0.0...1.0, step: 0.01, default: 0.3),
                tier: .filter
            )
        ])
    }
    func value(forKey key: String) -> SettingChange.Value? {
        key == "minimumConfidence" ? .float(minimumConfidence) : nil
    }
    mutating func setValue(_ value: SettingChange.Value, forKey key: String) {
        if case ("minimumConfidence", .float(let v)) = (key, value) { minimumConfidence = v }
    }
}

private struct ConfidenceOnlyDetector: TunableDetector {
    typealias Settings = ConfidenceOnlySettings
    let settings = ConfidenceOnlySettings()
    let availability: DetectorAvailability = .available
    let modelIdentifier = "mock.confidenceOnly"
    var capabilities: DetectorCapabilities {
        DetectorCapabilities(
            geometryKinds: [.box],
            confidence: .probabilistic,
            tunableKnobs: ConfidenceOnlySettings.schema,
            introspectableFields: []
        )
    }
    func prewarm() async {}
    func detect(in _: Frame) async throws -> [Detection] { [] }
    func apply(_: SettingChange) -> ApplyResult { .filter(transform: { $0 }) }
}

/// A detector whose confidence floor uses the **YOLO/Core ML decoder**
/// convention key `"confidenceThreshold"` (NOT Vision's `"minimumConfidence"`),
/// plus one non-confidence knob. Mirrors `YOLO26n`'s shape: its single tunable
/// is the `"confidenceThreshold"` floor — the knob that was previously leaking
/// through as a regular slider because the view only matched `"minimumConfidence"`.
private struct YOLOStyleSettings: DetectorSettings {
    var confidenceThreshold: Float = 0.25
    var maxDetections: Int = 300

    static var schema: SettingSchema {
        SettingSchema(knobs: [
            SettingSchema.Knob(
                key: "confidenceThreshold",
                label: "Min confidence",
                kind: .float(range: 0.0...1.0, step: 0.05, default: 0.25),
                tier: .filter
            ),
            SettingSchema.Knob(
                key: "maxDetections",
                label: "Max detections",
                kind: .int(range: 1...300, step: 1, default: 300),
                tier: .detector
            ),
        ])
    }

    func value(forKey key: String) -> SettingChange.Value? {
        switch key {
        case "confidenceThreshold": return .float(confidenceThreshold)
        case "maxDetections": return .int(maxDetections)
        default: return nil
        }
    }

    mutating func setValue(_ value: SettingChange.Value, forKey key: String) {
        switch (key, value) {
        case ("confidenceThreshold", .float(let v)): confidenceThreshold = v
        case ("maxDetections", .int(let v)): maxDetections = v
        default: break
        }
    }
}

private struct YOLOStyleDetector: TunableDetector {
    typealias Settings = YOLOStyleSettings
    let settings = YOLOStyleSettings()
    let availability: DetectorAvailability = .available
    let modelIdentifier = "mock.yoloStyle"
    var capabilities: DetectorCapabilities {
        DetectorCapabilities(
            geometryKinds: [.box],
            confidence: .probabilistic,
            tunableKnobs: YOLOStyleSettings.schema,
            introspectableFields: []
        )
    }
    func prewarm() async {}
    func detect(in _: Frame) async throws -> [Detection] { [] }
    func apply(_: SettingChange) -> ApplyResult { .filter(transform: { $0 }) }
}

// MARK: - Confidence-control suppression (the whole point)

@Test
func confidenceNoneYieldsNoConfidenceControl() {
    // Rectangles-shape profile: confidence `.none`, a confidence knob is
    // NOT present, geometry knobs only. No confidence control of any kind.
    let caps = capabilities(confidence: .none, knobs: [aspectKnob, maxObsKnob])
    let controls = CapabilityTuningProjection.controls(for: caps)

    #expect(!controls.contains(.confidenceSlider(key: "minimumConfidence")))
    #expect(!controls.contains(.confidenceInfo))
    #expect(
        controls.allSatisfy { if case .derivedQuality = $0 { return false } else { return true } })
    // The geometry knobs still render.
    #expect(controls.contains(.slider(key: "minimumAspectRatio")))
    #expect(controls.contains(.stepper(key: "maximumObservations")))
}

@Test
func confidenceNoneIgnoresAStrayConfidenceKnob() {
    // Even if a `.none` profile somehow carries a minimumConfidence knob,
    // the semantics gate the control off — honesty over knob presence.
    let caps = capabilities(confidence: .none, knobs: [confidenceKnob, aspectKnob])
    let controls = CapabilityTuningProjection.controls(for: caps)
    #expect(!controls.contains(.confidenceSlider(key: "minimumConfidence")))
    #expect(!controls.contains(.confidenceInfo))
    // And the stray confidence knob is NOT rendered as a regular slider
    // either (it's filtered out of the non-confidence partition).
    #expect(!controls.contains(.slider(key: "minimumConfidence")))
}

@Test
func perElementConfidenceWithKnobYieldsConfidenceSlider() {
    // Mock-pose-shape profile: `.perElement` confidence + a confidence
    // floor knob → a confidence slider appears (and is FIRST).
    let caps = capabilities(
        confidence: .perElement,
        knobs: [confidenceKnob, handsKnob, modelEnumKnob]
    )
    let controls = CapabilityTuningProjection.controls(for: caps)

    #expect(controls.first == .confidenceSlider(key: "minimumConfidence"))
    #expect(controls.contains(.toggle(key: "detectsHands")))
    #expect(controls.contains(.picker(key: "model")))
}

@Test
func probabilisticConfidenceWithoutKnobYieldsConfidenceInfo() {
    // Real confidence but no tunable floor knob → an honest info row,
    // not a fabricated slider.
    let caps = capabilities(confidence: .probabilistic, knobs: [aspectKnob])
    let controls = CapabilityTuningProjection.controls(for: caps)
    #expect(controls.contains(.confidenceInfo))
    #expect(!controls.contains(.confidenceSlider(key: "minimumConfidence")))
}

@Test
func derivedScalarYieldsReadOnlyQualityRow() {
    // The labeled-quality escape valve — shown as data, never an editable
    // confidence knob.
    let caps = capabilities(
        confidence: .derivedScalar(label: "quadrature quality"),
        knobs: [aspectKnob]
    )
    let controls = CapabilityTuningProjection.controls(for: caps)
    #expect(controls.contains(.derivedQuality(label: "quadrature quality")))
    #expect(!controls.contains(.confidenceSlider(key: "minimumConfidence")))
    #expect(!controls.contains(.confidenceInfo))
}

// MARK: - SettingKind → control mapping (string / enum get their UI)

@Test
func stringKnobYieldsTextField() {
    let caps = capabilities(confidence: .none, knobs: [customWordKnob])
    let controls = CapabilityTuningProjection.controls(for: caps)
    #expect(controls == [.textField(key: "customWord")])
}

@Test
func enumKnobYieldsPicker() {
    let caps = capabilities(confidence: .none, knobs: [modelEnumKnob])
    let controls = CapabilityTuningProjection.controls(for: caps)
    #expect(controls == [.picker(key: "model")])
}

@Test
func floatYieldsSliderIntYieldsStepperToggleYieldsToggleMultiSelectYieldsChips() {
    let caps = capabilities(
        confidence: .none,
        knobs: [aspectKnob, maxObsKnob, handsKnob, classesKnob]
    )
    let controls = CapabilityTuningProjection.controls(for: caps)
    #expect(
        controls == [
            .slider(key: "minimumAspectRatio"),
            .stepper(key: "maximumObservations"),
            .toggle(key: "detectsHands"),
            .chips(key: "classes"),
        ])
}

// MARK: - Rectangles vs. mock-pose, through the real detectors

@Test
func rectanglesDetectorDerivesNoConfidenceControl() {
    // The real rectangles detector's capabilities → no confidence
    // control, the four geometry/limit knobs present.
    let caps = VisionRectanglesDetector().capabilities
    let controls = CapabilityTuningProjection.controls(for: caps)

    #expect(!controls.contains(.confidenceSlider(key: "minimumConfidence")))
    #expect(!controls.contains(.confidenceInfo))
    #expect(controls.contains(.slider(key: "minimumAspectRatio")))
    #expect(controls.contains(.slider(key: "maximumAspectRatio")))
    #expect(controls.contains(.slider(key: "minimumSize")))
    #expect(controls.contains(.slider(key: "quadratureToleranceDegrees")))
    #expect(controls.contains(.stepper(key: "maximumObservations")))
}

// MARK: - Confidence suppression (redesign: global Min confidence replaces it)
//
// The redesigned inspector renders ONE global "Min confidence" floor in the
// Display group, so the detector's own confidence affordance is suppressed in
// the per-detector knob view via `CapabilityTuningView(hidesConfidence:)`. The
// non-confidence knobs still render; `hasVisibleControls` reports whether the
// knob box would draw anything (so the caller can drop an empty box).

@Test
@MainActor
func hidesConfidenceSuppressesAffordanceButKeepsOtherKnobs() {
    // A `.perElement` detector with a confidence floor knob + other knobs.
    // With suppression on, the confidence row is gone but `hasVisibleControls`
    // is still true (the other knobs remain).
    let model = TuningModel(detector: MockPoseDetector())

    let suppressed = CapabilityTuningView(model: model, hidesConfidence: true)
    #expect(suppressed.hasVisibleControls)  // detectsHands + model enum remain

    // Default (un-suppressed) keeps the affordance — unchanged behavior.
    let shown = CapabilityTuningView(model: model, hidesConfidence: false)
    #expect(shown.hasVisibleControls)
}

@Test
@MainActor
func rectanglesWithConfidenceSuppressedStillHasGeometryKnobs() {
    // Rectangles is `.none` confidence already; suppression is a no-op for the
    // confidence row, and its four geometry/limit knobs keep the box non-empty.
    let model = TuningModel(detector: VisionRectanglesDetector())
    let view = CapabilityTuningView(model: model, hidesConfidence: true)
    #expect(view.hasVisibleControls)
}

@Test
@MainActor
func detectorWithOnlyConfidenceKnobSuppressedYieldsNoVisibleControls() {
    // A profile whose ONLY knob is the confidence floor: suppressing confidence
    // leaves nothing, so `hasVisibleControls` is false and the caller can omit
    // the empty knob box (rendering just the detector name).
    let model = TuningModel(detector: ConfidenceOnlyDetector())
    let suppressed = CapabilityTuningView(model: model, hidesConfidence: true)
    #expect(!suppressed.hasVisibleControls)

    // Un-suppressed, the confidence slider is the one visible control.
    let shown = CapabilityTuningView(model: model, hidesConfidence: false)
    #expect(shown.hasVisibleControls)
}

// MARK: - YOLO-style confidence key (`confidenceThreshold`) is recognized too

@Test
func yoloConfidenceThresholdKnobDerivesAsConfidenceNotARegularSlider() {
    // YOLO26n keys its floor `"confidenceThreshold"`, not `"minimumConfidence"`.
    // The derivation must treat it as the confidence affordance (a confidence
    // slider, shown FIRST) — NOT a stray regular slider that would render a
    // second "Min confidence" control. The other knob still renders.
    let caps = YOLOStyleDetector().capabilities
    let controls = CapabilityTuningProjection.controls(for: caps)

    // It's the confidence slider, first — and it is NOT a regular slider.
    #expect(controls.first == .confidenceSlider(key: "confidenceThreshold"))
    #expect(!controls.contains(.slider(key: "confidenceThreshold")))
    // The non-confidence knob is untouched.
    #expect(controls.contains(.stepper(key: "maxDetections")))
}

@Test
@MainActor
func yoloStyleConfidenceSuppressedRemovesItButKeepsOtherKnobs() {
    // With the confidence affordance suppressed (the redesign), a YOLO-style
    // detector's `confidenceThreshold` floor is gone entirely — it does NOT
    // resurface as a regular knob — while the `maxDetections` knob remains, so
    // the box still has visible controls.
    let model = TuningModel(detector: YOLOStyleDetector())

    let suppressed = CapabilityTuningView(model: model, hidesConfidence: true)
    #expect(suppressed.hasVisibleControls)  // maxDetections remains

    // The confidence knob is recognized by key under BOTH conventions.
    #expect(
        CapabilityTuningView<YOLOStyleDetector>.isConfidenceKnob(
            YOLOStyleSettings.schema.knobs[0]))
    #expect(
        !CapabilityTuningView<YOLOStyleDetector>.isConfidenceKnob(
            YOLOStyleSettings.schema.knobs[1]))
}

@Test
@MainActor
func yoloStyleWithOnlyConfidenceThresholdSuppressedYieldsNoVisibleControls() {
    // A detector whose ONLY knob is the YOLO-style confidence floor: with
    // confidence suppressed, NOTHING renders — proving `confidenceThreshold`
    // is filtered out of the non-confidence partition, not just `minimumConfidence`.
    struct OnlyThresholdSettings: DetectorSettings {
        var confidenceThreshold: Float = 0.25
        static var schema: SettingSchema {
            SettingSchema(knobs: [
                SettingSchema.Knob(
                    key: "confidenceThreshold",
                    label: "Min confidence",
                    kind: .float(range: 0.0...1.0, step: 0.05, default: 0.25),
                    tier: .filter
                )
            ])
        }
        func value(forKey key: String) -> SettingChange.Value? {
            key == "confidenceThreshold" ? .float(confidenceThreshold) : nil
        }
        mutating func setValue(_ value: SettingChange.Value, forKey key: String) {
            if case ("confidenceThreshold", .float(let v)) = (key, value) {
                confidenceThreshold = v
            }
        }
    }
    struct OnlyThresholdDetector: TunableDetector {
        typealias Settings = OnlyThresholdSettings
        let settings = OnlyThresholdSettings()
        let availability: DetectorAvailability = .available
        let modelIdentifier = "mock.onlyThreshold"
        var capabilities: DetectorCapabilities {
            DetectorCapabilities(
                geometryKinds: [.box],
                confidence: .probabilistic,
                tunableKnobs: OnlyThresholdSettings.schema,
                introspectableFields: []
            )
        }
        func prewarm() async {}
        func detect(in _: Frame) async throws -> [Detection] { [] }
        func apply(_: SettingChange) -> ApplyResult { .filter(transform: { $0 }) }
    }

    let model = TuningModel(detector: OnlyThresholdDetector())
    let suppressed = CapabilityTuningView(model: model, hidesConfidence: true)
    #expect(!suppressed.hasVisibleControls)

    let shown = CapabilityTuningView(model: model, hidesConfidence: false)
    #expect(shown.hasVisibleControls)
}

// MARK: - Value-variant extractors (binding projection helpers)

@Test
func valueExtractorsReadMatchingVariantsOnly() {
    typealias RectView = CapabilityTuningView<VisionRectanglesDetector>
    #expect(RectView.floatValue(.float(0.5)) == 0.5)
    #expect(RectView.floatValue(.int(3)) == nil)
    #expect(RectView.intValue(.int(7)) == 7)
    #expect(RectView.intValue(.float(7)) == nil)
    #expect(RectView.boolValue(.toggle(true)) == true)
    #expect(RectView.stringValue(.string("hi")) == "hi")
    #expect(RectView.multiSelectValue(.multiSelect(["a"])) == ["a"])
    #expect(RectView.floatValue(nil) == nil)
}

// MARK: - String-keyed mutation path the derived view binds through

@Test
@MainActor
func updateByKeyMutatesSettingsAndClassifies() {
    // The derived view writes by schema key. Raising minimumAspectRatio
    // is filter-tier per the rectangles classifier.
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumAspectRatio: 0.2)
    )
    let model = TuningModel(detector: detector)

    model.update(key: "minimumAspectRatio", to: .float(0.6))

    #expect(model.settings.minimumAspectRatio == 0.6)
    #expect(model.lastChange?.key == "minimumAspectRatio")
    #expect(model.lastChange?.newValue == .float(0.6))
    #expect(model.lastApplyTier == .filter)
}

@Test
@MainActor
func updateByKeyDetectorTierLowersAspectRatio() {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumAspectRatio: 0.6)
    )
    let model = TuningModel(detector: detector)

    // Lowering widens the window → detector-tier rebuild.
    model.update(key: "minimumAspectRatio", to: .float(0.2))

    #expect(model.lastApplyTier == .detector)
    #expect(model.detector?.settings.minimumAspectRatio == 0.2)
}

@Test
@MainActor
func updateByKeyNoOpOnIdenticalValue() {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(minimumAspectRatio: 0.5)
    )
    let model = TuningModel(detector: detector)

    model.update(key: "minimumAspectRatio", to: .float(0.5))
    // No change emitted on an identical write.
    #expect(model.lastChange == nil)
    #expect(model.lastApplyTier == nil)
}

@Test
@MainActor
func updateByUnknownKeyIsIgnored() {
    let detector = VisionRectanglesDetector()
    let model = TuningModel(detector: detector)

    model.update(key: "no-such-knob", to: .float(0.9))
    // Defensive guard: unknown key → no mutation, no change.
    #expect(model.lastChange == nil)
}

@Test
@MainActor
func bindingForKeyReadsAndWritesThroughClassifier() {
    let detector = VisionRectanglesDetector(
        settings: VisionRectanglesSettings(quadratureToleranceDegrees: 30.0)
    )
    let model = TuningModel(detector: detector)

    let binding = model.binding(forKey: "quadratureToleranceDegrees")
    #expect(binding.wrappedValue == .float(30.0))

    binding.wrappedValue = .float(10.0)
    #expect(model.settings.quadratureToleranceDegrees == 10.0)
    // Quadrature is filter-tier in both directions (M5).
    #expect(model.lastApplyTier == .filter)
}

// MARK: - Settings value-bridge round-trip (the new DetectorSettings API)

@Test
func settingsValueBridgeRoundTrips() {
    var s = VisionRectanglesSettings()
    #expect(s.value(forKey: "minimumAspectRatio") == .float(0.5))
    #expect(s.value(forKey: "maximumObservations") == .int(0))
    #expect(s.value(forKey: "label") == .string("rectangle"))
    #expect(s.value(forKey: "nope") == nil)

    s.setValue(.float(0.7), forKey: "minimumAspectRatio")
    #expect(s.minimumAspectRatio == 0.7)
    s.setValue(.int(12), forKey: "maximumObservations")
    #expect(s.maximumObservations == 12)
    s.setValue(.string("doc"), forKey: "label")
    #expect(s.label == "doc")

    // Mismatched variant is dropped, not coerced.
    s.setValue(.toggle(true), forKey: "minimumAspectRatio")
    #expect(s.minimumAspectRatio == 0.7)
}
