import Foundation

/// Tunable knob values for `VisionRectanglesDetector`. Mirrors the
/// detector's existing constructor parameters one-for-one; defaults
/// match the detector's current defaults exactly so the additive
/// `settings` property on the detector is backwards-compatible.
///
/// **Schema-derivation strategy (Phase 1).** Hand-rolled — the
/// `static var schema` enumerates every property here literally, with
/// each `Knob`'s worst-case `ChangeTier`. The drift risk between the
/// stored properties and the schema entries is real but small at one
/// settings type; revisit when a third concrete type lands. See
/// `plans/features/M4.md` "Risks".
public struct VisionRectanglesSettings: DetectorSettings {

    // MARK: - Knob values

    /// Minimum aspect ratio (short-side / long-side) for accepted
    /// rectangles. Mirrors `DetectRectanglesRequest.minimumAspectRatio`.
    /// Vision-side parameter, so widening (lowering) the cutoff is
    /// detector-tier; narrowing (raising) is filter-tier.
    public var minimumAspectRatio: Float

    /// Maximum aspect ratio for accepted rectangles. Mirrors
    /// `DetectRectanglesRequest.maximumAspectRatio`. Symmetric to
    /// `minimumAspectRatio`: widening (raising) is detector-tier;
    /// narrowing (lowering) is filter-tier.
    public var maximumAspectRatio: Float

    /// Smallest accepted rectangle as a fraction of the shortest image
    /// dimension. Mirrors `DetectRectanglesRequest.minimumSize`.
    /// Lowering admits smaller rectangles the model previously
    /// rejected (detector-tier); raising trims the existing list
    /// (filter-tier).
    public var minimumSize: Float

    /// Maximum number of rectangles to return. `0` means unlimited;
    /// mirrors Vision's default. Raising (or moving away from a finite
    /// cap toward `0`) is detector-tier — the model may emit more
    /// observations than it previously truncated. Lowering is
    /// filter-tier — trim the existing list.
    public var maximumObservations: Int

    /// How far each corner is allowed to deviate from 90° (in degrees)
    /// for a rectangle to be kept.
    ///
    /// **M5: a pure post-hoc filter, not a Vision request parameter.**
    /// Vision is asked for rectangles at a *fixed permissive* tolerance
    /// (`VisionRectanglesDetector.requestQuadratureToleranceDegrees`), so
    /// it returns the full candidate set; this knob then filters in Swift
    /// by computing each rectangle's four corner angles from the corner
    /// keypoints Vision already returns. That makes it **filter-tier in
    /// both directions** — tightening *or* loosening just re-runs the
    /// angle predicate over the cached detections, symmetric and instant.
    /// (Previously this forwarded to `DetectRectanglesRequest`, which made
    /// loosening a detector-tier cache-dump — the asymmetry M5 fixes.)
    public var quadratureToleranceDegrees: Float

    /// Label applied to every emitted `Detection`. Cosmetic from the
    /// model's perspective — relabeling existing cached detections is
    /// a filter-tier rewrite, not a re-inference.
    public var label: String

    // MARK: - Init

    public init(
        minimumAspectRatio: Float = 0.5,
        maximumAspectRatio: Float = 0.5,
        minimumSize: Float = 0.2,
        maximumObservations: Int = 0,
        quadratureToleranceDegrees: Float = 30.0,
        label: String = "rectangle"
    ) {
        self.minimumAspectRatio = minimumAspectRatio
        self.maximumAspectRatio = maximumAspectRatio
        self.minimumSize = minimumSize
        self.maximumObservations = maximumObservations
        self.quadratureToleranceDegrees = quadratureToleranceDegrees
        self.label = label
    }

    // MARK: - Schema

    /// Hand-rolled schema mirroring the stored properties above.
    /// Tiers are the *worst-case* per knob — the per-transition
    /// classifier in `VisionRectanglesDetector.apply(_:)` downgrades
    /// where appropriate.
    ///
    /// **M5: no `minimumConfidence` knob.** Vision rectangles have no
    /// probabilistic confidence (`RectangleObservation.confidence` is a
    /// constant `1.0`), so the slider was tuning nothing — the knob M5
    /// exists to delete. The detector's `capabilities.confidence` is
    /// `.none`.
    ///
    /// **`quadratureToleranceDegrees` is filter-tier now.** It became a
    /// pure post-hoc corner-angle filter (no longer a Vision request
    /// parameter), so its worst-case static tier is `.filter`, not
    /// `.detector` — tightening or loosening it never needs
    /// re-inference.
    ///
    /// `label` is intentionally omitted from the schema for now:
    /// although `SettingKind.string` now exists, no tuning UI surfaces
    /// label editing, so exposing it to generic schema consumers buys
    /// nothing. The property is still part of `settings` and
    /// participates in the classifier as a filter-tier transition when
    /// surfaced through `SettingChange`.
    /// KeyPath ↔ schema-key bridge — see `DetectorSettings.key(for:)`
    /// for the rationale. One entry per stored property the schema
    /// surfaces; `label` is intentionally absent (no UI surfaces it, so
    /// `TuningModel.update(\.label, to:)` still participates in the
    /// classifier as a worst-case-fallback path rather than going
    /// through the schema). `DetectorSettingsTests` audits the
    /// schema-vs-property drift; this map is a parallel drift surface
    /// that should stay in lockstep.
    public static func key(for keyPath: PartialKeyPath<Self>) -> String? {
        switch keyPath {
        case \Self.minimumAspectRatio: return "minimumAspectRatio"
        case \Self.maximumAspectRatio: return "maximumAspectRatio"
        case \Self.minimumSize: return "minimumSize"
        case \Self.maximumObservations: return "maximumObservations"
        case \Self.quadratureToleranceDegrees: return "quadratureToleranceDegrees"
        case \Self.label: return "label"
        default: return nil
        }
    }

    /// String-keyed value read — the value-side complement to
    /// `key(for:)` that the capability-derived UI uses to address knobs
    /// by their schema `key`. Stays in lockstep with the schema and the
    /// keyPath bridge (the `DetectorSettingsTests` audit pins all three).
    /// `label` is included so a future generic UI can edit it via the
    /// `.string` kind even though the schema doesn't surface it yet.
    public func value(forKey key: String) -> SettingChange.Value? {
        switch key {
        case "minimumAspectRatio": return .float(minimumAspectRatio)
        case "maximumAspectRatio": return .float(maximumAspectRatio)
        case "minimumSize": return .float(minimumSize)
        case "maximumObservations": return .int(maximumObservations)
        case "quadratureToleranceDegrees": return .float(quadratureToleranceDegrees)
        case "label": return .string(label)
        default: return nil
        }
    }

    /// String-keyed value write. Mismatched payload variants (e.g. a
    /// `.toggle` into a `.float` knob) are dropped — the conformer's
    /// table is the authority on each knob's type.
    public mutating func setValue(_ value: SettingChange.Value, forKey key: String) {
        switch (key, value) {
        case ("minimumAspectRatio", .float(let v)): minimumAspectRatio = v
        case ("maximumAspectRatio", .float(let v)): maximumAspectRatio = v
        case ("minimumSize", .float(let v)): minimumSize = v
        case ("maximumObservations", .int(let v)): maximumObservations = v
        case ("quadratureToleranceDegrees", .float(let v)): quadratureToleranceDegrees = v
        case ("label", .string(let v)): label = v
        default: break
        }
    }

    public static var schema: SettingSchema {
        SettingSchema(knobs: [
            SettingSchema.Knob(
                key: "minimumAspectRatio",
                label: "Minimum aspect ratio",
                kind: .float(range: 0.0...1.0, step: 0.01, default: 0.5),
                tier: .detector
            ),
            SettingSchema.Knob(
                key: "maximumAspectRatio",
                label: "Maximum aspect ratio",
                kind: .float(range: 0.0...1.0, step: 0.01, default: 0.5),
                tier: .detector
            ),
            SettingSchema.Knob(
                key: "minimumSize",
                label: "Minimum size",
                kind: .float(range: 0.0...1.0, step: 0.01, default: 0.2),
                tier: .detector
            ),
            SettingSchema.Knob(
                key: "maximumObservations",
                label: "Maximum observations",
                kind: .int(range: 0...100, step: 1, default: 0),
                tier: .detector
            ),
            SettingSchema.Knob(
                key: "quadratureToleranceDegrees",
                label: "Quadrature tolerance (°)",
                kind: .float(range: 0.0...45.0, step: 0.5, default: 30.0),
                tier: .filter
            ),
        ])
    }
}
