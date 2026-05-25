import SwiftUI

// MARK: - CapabilityTuningView

/// The capability-derived tuning UI — the payoff of M5's capability
/// model. Given any `TunableDetector`'s `DetectorCapabilities` (which
/// carries the `SettingSchema`) and confidence semantics, it renders one
/// control per knob and an honest confidence affordance, with **zero
/// per-detector authoring**. The UI cannot expose a knob the model
/// doesn't declare, and cannot show a confidence the model doesn't have.
///
/// **Derivation rules.**
///
///   - Each `SettingSchema.Knob` maps to a primitive by its
///     `SettingKind`: `.float` / `.int` → `TuningSlider`; `.toggle` →
///     `TuningToggle`; `.multiSelect` → `ClassFilterChips`; `.string` →
///     a `TextField`; `.enum` → a `Picker`. (`.string` / `.enum` are the
///     two kinds Wave 1 added; this is where they get their UI.)
///   - The **confidence affordance is gated purely on
///     `DetectorCapabilities.confidence`**, decoupled from the knob list:
///       - `.none` → no confidence section at all (rectangles). The whole
///         point: the UI can't surface a confidence the model lacks.
///       - `.probabilistic` / `.perElement` → a confidence-floor
///         `TuningSlider`, bound to the schema knob conventionally keyed
///         `"minimumConfidence"` when one is present. A detector with
///         real confidence that wants a tunable floor declares that knob;
///         a detector with real confidence but no floor knob shows the
///         section header without a slider (still honest: "this model has
///         confidence" without inventing a control).
///       - `.derivedScalar(label:)` → a **read-only** labeled row showing
///         the metric name. Never an editable "confidence" knob — the
///         labeled-quality-ratio escape valve from the capability
///         decision, surfaced as data, not a knob.
///
/// **Why `"minimumConfidence"` as the confidence-knob convention.** The
/// schema keys knobs by `String` and carries no "this knob is the
/// confidence floor" marker. Rather than add a marker axis no shipped
/// detector needs yet, the derived view treats the conventional key
/// `"minimumConfidence"` as the confidence floor — the same name Vision /
/// Core ML detectors use. Revisit if a detector needs a differently-named
/// confidence knob (logged as a hygiene item, not a Wave 2 blocker).
///
/// **Binding routing.** Every control binds through the model's
/// string-keyed `binding(forKey:)`, so writes route through
/// `TuningModel.update(key:to:)` → the tier classifier → cache
/// invalidation, identical to the typed `binding(_:)` path. No control
/// writes `settings` directly.
///
/// **Honest ratios.** Float controls in `[0, 1]` (confidence, aspect
/// ratio, size) render as fraction-digit ratios, never percentages,
/// per the capability-honest decision.
///
/// **Capabilities source.** Read from `model.detector?.capabilities`
/// (the live, possibly hot-swapped detector). A detector-less model
/// (constructed via `TuningModel(settings:)`) has no capabilities, so the
/// view falls back to rendering just the static `Settings.schema` knobs
/// with no confidence section — a safe, honest default.
@MainActor
public struct CapabilityTuningView<Detector: TunableDetector>: View {

    @Bindable public var model: TuningModel<Detector>

    /// Conventional schema key for a confidence-floor knob. See the
    /// type doc comment for why this is a convention rather than a marker.
    public static var confidenceKnobKey: String { "minimumConfidence" }

    public init(model: TuningModel<Detector>) {
        self.model = model
    }

    // MARK: Derived data

    /// The active capability descriptor, or `nil` for a detector-less
    /// model. Confidence semantics come from here; the knob list falls
    /// back to the static schema when absent.
    private var capabilities: DetectorCapabilities? {
        model.detector?.capabilities
    }

    /// Confidence semantics, defaulting to `.none` when no detector is
    /// present (no detector → no confidence affordance, the safe default).
    private var confidence: DetectorCapabilities.ConfidenceSemantics {
        capabilities?.confidence ?? .none
    }

    /// The full knob list — from the capability descriptor when present,
    /// else the static schema.
    private var knobs: [SettingSchema.Knob] {
        capabilities?.tunableKnobs.knobs ?? Detector.Settings.schema.knobs
    }

    /// Whether a confidence-floor control should appear: only when the
    /// model has real (probabilistic or per-element) confidence.
    private var showsConfidenceControl: Bool {
        switch confidence {
        case .probabilistic, .perElement: return true
        case .none, .derivedScalar: return false
        }
    }

    /// Knobs to render in the geometry/limits sections — everything
    /// except the confidence-floor knob (which the confidence section
    /// owns when shown).
    private var nonConfidenceKnobs: [SettingSchema.Knob] {
        knobs.filter { $0.key != Self.confidenceKnobKey }
    }

    /// The confidence-floor knob, if the schema declares one.
    private var confidenceKnob: SettingSchema.Knob? {
        knobs.first { $0.key == Self.confidenceKnobKey }
    }

    public var body: some View {
        Form {
            confidenceSection
            Section("Knobs") {
                ForEach(nonConfidenceKnobs, id: \.key) { knob in
                    control(for: knob)
                }
            }
        }
    }

    // MARK: Confidence section

    @ViewBuilder
    private var confidenceSection: some View {
        switch confidence {
        case .none:
            // No section — the model has no meaningful confidence.
            EmptyView()

        case .probabilistic, .perElement:
            if let knob = confidenceKnob, case .float(let range, let step, _) = knob.kind {
                Section("Confidence") {
                    TuningSlider(
                        label: knob.label,
                        value: floatBinding(forKey: knob.key),
                        range: range,
                        step: step
                    )
                }
            } else {
                // Real confidence, but no tunable floor knob declared.
                // Surface the fact honestly without inventing a control.
                Section("Confidence") {
                    Text(confidenceKindDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

        case .derivedScalar(let label):
            // A labeled quality ratio — read-only, never an editable
            // "confidence" knob.
            Section("Quality") {
                HStack {
                    Text(label)
                        .font(.callout)
                    Spacer()
                    Text("derived")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var confidenceKindDescription: String {
        switch confidence {
        case .probabilistic: return "Per-detection confidence (ratio)"
        case .perElement: return "Per-element confidence (ratio)"
        case .none, .derivedScalar: return ""
        }
    }

    // MARK: Per-knob control

    @ViewBuilder
    private func control(for knob: SettingSchema.Knob) -> some View {
        switch knob.kind {
        case .float(let range, let step, _):
            TuningSlider(
                label: knob.label,
                value: floatBinding(forKey: knob.key),
                range: range,
                step: step,
                // Degree-style ranges (> 1) read better at one fraction
                // digit; [0,1] ratios keep the default two. Never a
                // percentage — honest ratios per the capability decision.
                format: range.upperBound > 1
                    ? .number.precision(.fractionLength(1))
                    : nil
            )

        case .int(let range, let step, _):
            Stepper(
                value: intBinding(forKey: knob.key),
                in: range,
                step: step
            ) {
                HStack {
                    Text(knob.label)
                        .font(.callout)
                    Spacer()
                    Text("\(model.settings.value(forKey: knob.key).flatMap(Self.intValue) ?? 0)")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

        case .toggle:
            TuningToggle(
                label: knob.label,
                isOn: boolBinding(forKey: knob.key)
            )

        case .multiSelect(let options, _):
            VStack(alignment: .leading, spacing: 4) {
                Text(knob.label)
                    .font(.callout)
                ClassFilterChips(
                    allOptions: options,
                    selection: multiSelectBinding(forKey: knob.key)
                )
            }

        case .string:
            HStack {
                Text(knob.label)
                    .font(.callout)
                Spacer()
                TextField(knob.label, text: stringBinding(forKey: knob.key))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 160)
                    #if os(iOS)
                .textInputAutocapitalization(.never)
                    #endif
            }

        case .enum(let options, _):
            Picker(knob.label, selection: stringBinding(forKey: knob.key)) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        }
    }

    // MARK: Typed binding projections

    /// Project the model's erased `binding(forKey:)` to a `Binding<Float>`
    /// for the float controls. Reads default to `0` when the knob is
    /// absent / a non-float payload (the schema guarantees the kind, so
    /// this is defensive). Writes wrap the value back into `.float`.
    private func floatBinding(forKey key: String) -> Binding<Float> {
        Binding(
            get: { Self.floatValue(model.settings.value(forKey: key)) ?? 0 },
            set: { model.update(key: key, to: .float($0)) }
        )
    }

    private func intBinding(forKey key: String) -> Binding<Int> {
        Binding(
            get: { Self.intValue(model.settings.value(forKey: key)) ?? 0 },
            set: { model.update(key: key, to: .int($0)) }
        )
    }

    private func boolBinding(forKey key: String) -> Binding<Bool> {
        Binding(
            get: { Self.boolValue(model.settings.value(forKey: key)) ?? false },
            set: { model.update(key: key, to: .toggle($0)) }
        )
    }

    private func stringBinding(forKey key: String) -> Binding<String> {
        Binding(
            get: { Self.stringValue(model.settings.value(forKey: key)) ?? "" },
            set: { model.update(key: key, to: .string($0)) }
        )
    }

    private func multiSelectBinding(forKey key: String) -> Binding<Set<String>> {
        Binding(
            get: { Self.multiSelectValue(model.settings.value(forKey: key)) ?? [] },
            set: { model.update(key: key, to: .multiSelect($0)) }
        )
    }

    // MARK: Value-variant extractors (testable, pure)
    //
    // `nonisolated` because they're pure functions of the argument with
    // no main-actor state — this lets nonisolated tests call them and
    // keeps the binding getters allocation-free. (The enclosing `View`
    // is `@MainActor`; these statics opt out explicitly.)

    nonisolated static func floatValue(_ value: SettingChange.Value?) -> Float? {
        if case .float(let v)? = value { return v }
        return nil
    }

    nonisolated static func intValue(_ value: SettingChange.Value?) -> Int? {
        if case .int(let v)? = value { return v }
        return nil
    }

    nonisolated static func boolValue(_ value: SettingChange.Value?) -> Bool? {
        if case .toggle(let v)? = value { return v }
        return nil
    }

    nonisolated static func stringValue(_ value: SettingChange.Value?) -> String? {
        if case .string(let v)? = value { return v }
        return nil
    }

    nonisolated static func multiSelectValue(_ value: SettingChange.Value?) -> Set<String>? {
        if case .multiSelect(let v)? = value { return v }
        return nil
    }
}

// MARK: - Derived control descriptor (testable derivation)

/// The control the derived view will render for one knob — extracted so
/// the **derivation mapping** can be unit-tested without instantiating
/// SwiftUI. `CapabilityTuningProjection.controls(for:)` is the single
/// source of truth for "which control, for which capability profile,"
/// and the view's `body` renders exactly this set.
public enum DerivedControl: Sendable, Equatable {
    /// A confidence-floor slider (shown only for real-confidence models
    /// that declare a `minimumConfidence` knob).
    case confidenceSlider(key: String)
    /// A read-only "this model has confidence but no tunable floor" row.
    case confidenceInfo
    /// A read-only labeled derived-quality row.
    case derivedQuality(label: String)
    /// A float slider for a knob.
    case slider(key: String)
    /// An int stepper for a knob.
    case stepper(key: String)
    /// A bool toggle for a knob.
    case toggle(key: String)
    /// A multi-select chip cluster for a knob.
    case chips(key: String)
    /// A free-form string text field for a knob.
    case textField(key: String)
    /// A single-choice picker for a knob.
    case picker(key: String)
}

/// Pure derivation: capability profile (confidence semantics + schema)
/// → ordered list of `DerivedControl`s. This is exactly what
/// `CapabilityTuningView.body` renders; keeping it a free function makes
/// the mapping testable in isolation (CLAUDE.md: catch UI-logic bugs at
/// the artifact level, like a unit test).
public enum CapabilityTuningProjection {

    static var confidenceKnobKey: String { "minimumConfidence" }

    /// Derive the control list for a capability descriptor. Order matches
    /// the view: confidence affordance first, then the remaining knobs in
    /// schema order.
    public static func controls(
        for capabilities: DetectorCapabilities
    ) -> [DerivedControl] {
        var out: [DerivedControl] = []

        let knobs = capabilities.tunableKnobs.knobs
        let confidenceKnob = knobs.first { $0.key == confidenceKnobKey }

        switch capabilities.confidence {
        case .none:
            break  // no confidence affordance at all
        case .probabilistic, .perElement:
            if let knob = confidenceKnob, case .float = knob.kind {
                out.append(.confidenceSlider(key: knob.key))
            } else {
                out.append(.confidenceInfo)
            }
        case .derivedScalar(let label):
            out.append(.derivedQuality(label: label))
        }

        for knob in knobs where knob.key != confidenceKnobKey {
            switch knob.kind {
            case .float: out.append(.slider(key: knob.key))
            case .int: out.append(.stepper(key: knob.key))
            case .toggle: out.append(.toggle(key: knob.key))
            case .multiSelect: out.append(.chips(key: knob.key))
            case .string: out.append(.textField(key: knob.key))
            case .enum: out.append(.picker(key: knob.key))
            }
        }

        return out
    }
}

// MARK: - Preview

#if DEBUG

/// Preview-only settings type exercising the *contrasting* capability
/// profile: a `.perElement`-confidence detector with a `.enum` knob and
/// a `.toggle`, plus the conventional `minimumConfidence` floor. Stands
/// in for a body-pose-style detector without shipping the real one
/// (that's P3) — enough to prove the derivation adapts.
private struct MockPoseSettings: DetectorSettings {
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

    static func key(for keyPath: PartialKeyPath<Self>) -> String? {
        switch keyPath {
        case \Self.minimumConfidence: return "minimumConfidence"
        case \Self.detectsHands: return "detectsHands"
        case \Self.model: return "model"
        default: return nil
        }
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

/// Preview-only `TunableDetector` with `.perElement` confidence — the
/// honest mirror image of rectangles' `.none`.
private struct MockPoseDetector: TunableDetector {
    typealias Settings = MockPoseSettings

    let settings: MockPoseSettings
    let availability: DetectorAvailability = .available
    let modelIdentifier = "mock.pose"

    var capabilities: DetectorCapabilities {
        DetectorCapabilities(
            geometryKinds: [.keypoints],
            confidence: .perElement,
            tunableKnobs: MockPoseSettings.schema,
            introspectableFields: [
                DetectorCapabilities.IntrospectableField(
                    key: "joints",
                    displayName: "Joints",
                    valueKind: .keypoints,
                    source: .keypoints
                )
            ]
        )
    }

    init(settings: MockPoseSettings = MockPoseSettings()) {
        self.settings = settings
    }

    func prewarm() async {}
    func detect(in _: Frame) async throws -> [Detection] { [] }
    func apply(_: SettingChange) -> ApplyResult { .filter(transform: { $0 }) }
}

#Preview("CapabilityTuningView · rectangles (confidence .none)") {
    CapabilityTuningView(
        model: TuningModel(
            detector: VisionRectanglesDetector(
                settings: VisionRectanglesSettings(
                    minimumAspectRatio: 0.3,
                    maximumAspectRatio: 1.0,
                    minimumSize: 0.1,
                    quadratureToleranceDegrees: 30.0
                )
            )
        )
    )
    .frame(width: 360, height: 480)
}

#Preview("CapabilityTuningView · mock pose (confidence .perElement + enum)") {
    CapabilityTuningView(
        model: TuningModel(detector: MockPoseDetector())
    )
    .frame(width: 360, height: 480)
}

#Preview("CapabilityTuningView · both profiles side-by-side") {
    HStack(spacing: 16) {
        VStack {
            Text("Rectangles · .none").font(.caption).bold()
            CapabilityTuningView(
                model: TuningModel(detector: VisionRectanglesDetector())
            )
        }
        VStack {
            Text("Mock pose · .perElement").font(.caption).bold()
            CapabilityTuningView(
                model: TuningModel(detector: MockPoseDetector())
            )
        }
    }
    .frame(width: 760, height: 480)
    .padding()
}

#endif
