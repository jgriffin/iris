/// Structured, `Sendable` descriptor of what a detector *actually* produces
/// and exposes — the single source of truth M5 ("honest detectors") hangs on.
///
/// **The motivating bug.** A flat `[Detection]` with a `confidence: Float`
/// can't tell the truth about Vision's detector surface: `RectangleObservation`
/// reports a constant `1.0` (geometric, not probabilistic), pose carries real
/// confidence *per joint*, classification has no geometry at all. A detector
/// that ships a confidence slider it can't honor, or an overlay that draws a
/// "100%" chip from a constant, is lying about the model. `DetectorCapabilities`
/// makes the model declare what it can do so the tuning UI, the overlay, and the
/// raw-data inspector each *project* from one descriptor instead of re-deriving
/// (and drifting from) the truth.
///
/// **Four axes** (per the 2026-05-24 "Detector capability model" decision, which
/// derives them from the observed variance in the Vision capability matrix —
/// `explorations/2026-05-24-vision-capability-audit/`):
///
///   1. ``geometryKinds`` — a *set*: a detector can carry more than one geometry
///      (face landmarks = box **and** keypoints; barcodes = quad **and** payload).
///   2. ``confidence`` — the spine. Probabilistic vs. per-element vs. none vs. a
///      labeled derived scalar. Never a bare `confidence: Float` that fabricates
///      certainty.
///   3. ``tunableKnobs`` — reuses the existing ``SettingSchema``; no parallel
///      mechanism.
///   4. ``introspectableFields`` — the structured field list both the Wave 2
///      filter UI and the future P4 inspector read. The single place that
///      enumerates a detection's payload, so the two consumers can't drift.
///
/// **Renderability vs. inspectability are projections, not stored axes.** P3's
/// overlay draws from ``geometryKinds``; P4's inspector lists from
/// ``introspectableFields``. Keeping them as two views of *one* value is what
/// the decision means by "two projections of the same descriptor."
///
/// **Scope (Wave 1).** Only the two M5 exemplars exercise this: rectangles
/// (confidence `.none`, geometry quad+box) and — landing later — 2D human body
/// pose (confidence `.perElement`, geometry keypoints). The geometry and field
/// enums carry cases the matrix surfaced (`contour`, `mask`, `heatmap`, …) so
/// the model is honest about *naming* a capability it doesn't yet render, but
/// no payload is modeled for kinds no shipped detector produces — that's the
/// over-design risk the milestone plan warns against.
public struct DetectorCapabilities: Sendable, Hashable {

    /// Every geometry kind this detector's detections can carry. A *set*
    /// because a single detection may be both a box and a keypoint cloud
    /// (face landmarks) or a quad and a decoded payload (barcodes).
    public let geometryKinds: Set<GeometryKind>

    /// How (or whether) this detector's confidence is meaningful. The
    /// spine of the capability model — see ``ConfidenceSemantics``.
    public let confidence: ConfidenceSemantics

    /// The detector's tunable knobs, as the existing ``SettingSchema``.
    /// Reused rather than reinvented so the tuning channel
    /// (`SettingChange` / `ApplyResult` / `TuningModel`) needs no parallel
    /// machinery. A detector with no knobs declares an empty schema.
    public let tunableKnobs: SettingSchema

    /// The structured fields a detection of this kind carries — the single
    /// source of truth for the Wave 2 filter UI and the P4 inspector.
    /// Order is display order.
    public let introspectableFields: [IntrospectableField]

    public init(
        geometryKinds: Set<GeometryKind>,
        confidence: ConfidenceSemantics,
        tunableKnobs: SettingSchema,
        introspectableFields: [IntrospectableField]
    ) {
        self.geometryKinds = geometryKinds
        self.confidence = confidence
        self.tunableKnobs = tunableKnobs
        self.introspectableFields = introspectableFields
    }
}

// MARK: - GeometryKind

extension DetectorCapabilities {

    /// The spatial shape(s) a detector's output occupies. Drawn from the
    /// Vision capability matrix's "Geometry" column. Wave 1 wires payloads
    /// only for `box` / `quad` / `keypoints` (the two exemplars); the
    /// remaining cases exist so a detector can *name* its geometry honestly
    /// even before P3 renders it — P3/P4 then fail loudly ("not yet
    /// rendered") rather than faking a box.
    public enum GeometryKind: Sendable, Hashable, CaseIterable {
        /// Axis-aligned rectangle (`Detection.boundingBox`).
        case box
        /// Oriented quadrilateral — four corners that need not form an
        /// axis-aligned box (rectangles, barcodes, document segmentation).
        /// Carried in `Detection.keypoints` in corner order.
        case quad
        /// A skeleton / landmark constellation of named points
        /// (`Detection.keypoints`), e.g. body or hand pose.
        case keypoints
        /// Nested polyline paths (contour detection). No `Detection`
        /// payload yet — named only.
        case contour
        /// Per-instance or per-pixel segmentation mask
        /// (`Detection.mask`). Payload shape still a TODO.
        case mask
        /// Dense per-pixel scalar field (saliency / objectness). No
        /// `Detection` payload yet — named only.
        case heatmap
        /// No geometry at all — a whole-image label (classification).
        case labelOnly
        /// A single scalar value, not a region (horizon angle, aesthetics
        /// score). No `Detection` payload yet — named only.
        case scalar
    }
}

// MARK: - ConfidenceSemantics

extension DetectorCapabilities {

    /// What a detector's confidence *means* — the distinction a flat
    /// `confidence: Float` erases and M5 exists to restore.
    ///
    /// `Detection.confidence` remains a field on the value type (every
    /// detection still has *a* number), but this enum tells consumers
    /// whether that number is a real probability, a per-element artifact,
    /// meaningless, or a quality ratio wearing a label. The overlay (P3)
    /// uses it to decide whether to draw a confidence chip; the inspector
    /// (P4) uses it to label or suppress the field.
    public enum ConfidenceSemantics: Sendable, Hashable {

        /// A genuine whole-observation probability in `[0, 1]`
        /// (classification, human/face rectangles, animals, barcodes,
        /// document segmentation, trajectories). `Detection.confidence`
        /// is meaningful and may be shown as a ratio.
        case probabilistic

        /// Confidence lives per element — per keypoint / per text
        /// candidate (pose family, text recognition). The
        /// whole-`Detection.confidence` is an aggregate at best; the real
        /// signal is on `Detection.Keypoint.confidence`.
        case perElement

        /// No meaningful confidence. The detector reports a constant
        /// (rectangles' `1.0`) or a purely geometric result (contours,
        /// horizon, masks, saliency). Consumers MUST NOT surface
        /// `Detection.confidence` as if it were a probability — there is
        /// nothing to show.
        case none

        /// A labeled quality metric that *looks* like confidence but is
        /// not a detection probability — face capture quality, image
        /// aesthetics, or a rectangle's quadrature/aspect quality ratio.
        ///
        /// This is the honest escape valve from the milestone's open
        /// question "are we quietly reintroducing confidence as a quality
        /// ratio?": yes, a geometric detector *may* surface a derived
        /// quality number, but only behind this explicit label, and never
        /// laundered into `Detection.confidence`. `label` is the
        /// human-readable name of the metric (e.g. `"quadrature quality"`).
        case derivedScalar(label: String)
    }
}

// MARK: - IntrospectableField

extension DetectorCapabilities {

    /// One field a detection of this kind carries — the structured atom the
    /// Wave 2 filter UI and the P4 inspector both project from.
    ///
    /// **Why a flat descriptor, not a fixed `box/keypoint/mask` triple.**
    /// The inspector must render "what really comes back" generically, and
    /// the filter UI must offer controls only over fields that exist. A
    /// hand-maintained per-detector field list would drift from the actual
    /// `Detection`; enumerating fields here — keyed to where they live on
    /// `Detection` via ``Source`` — keeps both consumers reading one list.
    ///
    /// **Kept minimal (Wave 1).** Only the field *kinds* the two exemplars
    /// demand are modeled: geometry payloads (box, quad corners, keypoints),
    /// the label, and per-keypoint confidence. Richer extras the matrix
    /// noted (barcode payload string, text candidates, face pose angles) are
    /// deliberately *not* pre-modeled — they land when a detector that emits
    /// them ships, per the over-design caveat in the recommendations.
    public struct IntrospectableField: Sendable, Hashable {

        /// Stable identifier for the field (e.g. `"boundingBox"`,
        /// `"corners"`, `"joints"`, `"label"`). Distinct from a human label
        /// so consumers can key projections off it.
        public let key: String

        /// Human-readable name for inspector display.
        public let displayName: String

        /// The data shape of this field — drives how the inspector renders
        /// it and whether the filter UI can offer a control.
        public let valueKind: ValueKind

        /// Where this field lives on the `Detection` value, so a generic
        /// projection can read it without a per-detector switch.
        public let source: Source

        public init(
            key: String,
            displayName: String,
            valueKind: ValueKind,
            source: Source
        ) {
            self.key = key
            self.displayName = displayName
            self.valueKind = valueKind
            self.source = source
        }

        /// The data shape of an introspectable field. Kept to exactly what
        /// the two exemplars carry — extend when a detector forces it.
        public enum ValueKind: Sendable, Hashable {
            /// An axis-aligned `CGRect` (`Detection.boundingBox`).
            case boundingBox
            /// A list of named, positioned, optionally-confident points
            /// (`Detection.keypoints`) — quad corners or a pose skeleton.
            case keypoints
            /// A text label (`Detection.label`).
            case label
            /// A scalar in `[0, 1]` — used for per-keypoint confidence and,
            /// behind a `derivedScalar` confidence semantics, a labeled
            /// quality ratio.
            case scalar
        }

        /// Where the field is sourced from on the `Detection` value type.
        /// Lets a generic projection (inspector / filter UI) locate the
        /// data without hand-written per-detector accessors.
        public enum Source: Sendable, Hashable {
            /// `Detection.boundingBox`.
            case boundingBox
            /// `Detection.label`.
            case label
            /// `Detection.confidence`.
            case confidence
            /// `Detection.keypoints`.
            case keypoints
        }
    }
}
