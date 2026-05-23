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

    /// How far each corner is allowed to deviate from 90° (in degrees).
    /// Mirrors `DetectRectanglesRequest.quadratureToleranceDegrees`.
    /// Raising admits more-skewed shapes the model previously rejected
    /// (detector-tier); lowering trims the existing list (filter-tier).
    public var quadratureToleranceDegrees: Float

    /// Minimum confidence cutoff. Mirrors
    /// `DetectRectanglesRequest.minimumConfidence`. Vision uses this
    /// as a model parameter: lowering it surfaces detections that the
    /// model previously suppressed (detector-tier). Raising it hides
    /// detections we already have (filter-tier).
    public var minimumConfidence: Float

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
        minimumConfidence: Float = 0.0,
        label: String = "rectangle"
    ) {
        self.minimumAspectRatio = minimumAspectRatio
        self.maximumAspectRatio = maximumAspectRatio
        self.minimumSize = minimumSize
        self.maximumObservations = maximumObservations
        self.quadratureToleranceDegrees = quadratureToleranceDegrees
        self.minimumConfidence = minimumConfidence
        self.label = label
    }

    // MARK: - Schema

    /// Hand-rolled schema mirroring the stored properties above.
    /// Tiers are the *worst-case* per knob — the per-transition
    /// classifier in `VisionRectanglesDetector.apply(_:)` downgrades
    /// where appropriate.
    ///
    /// `label` is intentionally omitted from the schema for Phase 1:
    /// it's a `String` knob, and `SettingKind` has no string-payload
    /// variant yet (the four shapes are float / int / toggle /
    /// multiSelect). The property is still part of `settings` and
    /// participates in the classifier as a filter-tier transition
    /// when surfaced through `SettingChange`; it just isn't exposed
    /// to generic schema consumers. TODO M4 Phase 2: add
    /// `SettingKind.string(default:)` when the tuning UI actually
    /// surfaces label editing.
    /// KeyPath ↔ schema-key bridge — see `DetectorSettings.key(for:)`
    /// for the rationale. One entry per stored property the schema
    /// surfaces; `label` is intentionally absent (no `.string` knob
    /// variant yet, so `TuningModel.update(\.label, to:)` still
    /// participates in the classifier as a worst-case-fallback path
    /// rather than going through the schema). `DetectorSettingsTests`
    /// audits the schema-vs-property drift; this map is a parallel
    /// drift surface that should stay in lockstep.
    public static func key(for keyPath: PartialKeyPath<Self>) -> String? {
        switch keyPath {
        case \Self.minimumAspectRatio: return "minimumAspectRatio"
        case \Self.maximumAspectRatio: return "maximumAspectRatio"
        case \Self.minimumSize: return "minimumSize"
        case \Self.maximumObservations: return "maximumObservations"
        case \Self.quadratureToleranceDegrees: return "quadratureToleranceDegrees"
        case \Self.minimumConfidence: return "minimumConfidence"
        case \Self.label: return "label"
        default: return nil
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
                tier: .detector
            ),
            SettingSchema.Knob(
                key: "minimumConfidence",
                label: "Minimum confidence",
                kind: .float(range: 0.0...1.0, step: 0.01, default: 0.0),
                tier: .detector
            ),
        ])
    }
}
