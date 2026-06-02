import CoreGraphics
import Vision

/// The pluggable seam that turns a Core ML model's raw Vision output into
/// Iris `Detection` values.
///
/// **Why a seam, not two detectors.** The decisive fork in running a
/// converted detector is *how its output is decoded*, and that's a fact about
/// the exported `.mlpackage`, not a Swift choice (per the M6 design spine and
/// `explorations/2026-05-25-coreml-model-conversion/RECOMMENDATIONS.md` §2):
///
///   - **Path A** — the model is an Apple `NonMaximumSuppression` pipeline
///     (`coordinates` + `confidence` outputs). Vision auto-decodes it into
///     ready-made `RecognizedObjectObservation` values. `VisionObjectDecoder`
///     reads box + label + confidence straight off them; *zero* Swift decode.
///   - **Path B** — anything else comes back as a raw `MLMultiArray`
///     observation the decoder reshapes/thresholds in Swift
///     (`YOLOEnd2EndDecoder`, lands in M6·P3; `DETRSetPredictionDecoder`
///     later).
///
/// Modeling the two paths as one `CoreMLDetector` carrying a swappable
/// `OutputDecoder` keeps the inference plumbing (model load, crop/scale,
/// `CoreMLRequest.perform`) in one place and lets new model families slot in
/// by conforming a new decoder.
///
/// **Concurrency.** `Sendable` so `CoreMLDetector` (which holds a decoder)
/// stays `Sendable` and crosses actor boundaries with the rest of the
/// pipeline. Decoders are stateless value types.
public protocol OutputDecoder: Sendable {

    /// Turn the Vision observations a `CoreMLRequest` produced into
    /// `Detection` values.
    ///
    /// - Parameters:
    ///   - observations: The request's result — `[any VisionObservation]`.
    ///     For a path-A pipeline these are `RecognizedObjectObservation`s;
    ///     for path B they are `CoreMLFeatureValueObservation`s wrapping an
    ///     `MLMultiArray`.
    ///   - frameSize: The upright source-frame size, for decoders that need
    ///     pixel-space math. Path-A decoders ignore it (Vision already
    ///     returns normalized boxes in the source frame's space).
    ///   - modelID: The producing detector's `modelIdentifier`, stamped onto
    ///     each `Detection.sourceModelID`.
    func decode(
        _ observations: [any VisionObservation],
        frameSize: CGSize,
        modelID: String
    ) throws -> [Detection]

    /// The full class set this decoder can map a detection onto, or `nil` when
    /// the decoder carries no statically-known label set. Surfaced by the
    /// wrapping `CoreMLDetector` as `DetectorCapabilities.availableLabels` — the
    /// single source of truth for the M10 per-class tuning roster.
    ///
    /// A raw-tensor path-B decoder (``YOLOEnd2EndDecoder``) is constructed with
    /// its `labels`, so it knows the whole class set up front and returns it. A
    /// path-A ``VisionObjectDecoder`` reads a `NonMaximumSuppression` pipeline
    /// whose label list is baked into the model and only surfaces *per
    /// detection* at decode time — the decoder holds no static roster, so it
    /// keeps the `nil` default.
    var availableLabels: [String]? { get }
}

extension OutputDecoder {
    /// Default: no statically-known class set. A decoder whose labels are
    /// supplied at construction overrides this.
    public var availableLabels: [String]? { nil }
}

/// An ``OutputDecoder`` that carries a runtime-tunable **confidence
/// threshold** — the path-B knob M6·P3 adds.
///
/// **Why a sub-protocol, not a field on `OutputDecoder`.** The two decode
/// paths differ on whether the threshold is *tunable at runtime at all*:
///
///   - **Path A** (`VisionObjectDecoder`) reads a `nms=True` pipeline whose
///     confidence/IoU thresholds are **baked at export time** — there is no
///     runtime knob to honor, so it stays a plain ``OutputDecoder`` and the
///     detector wrapping it stays a plain `Detector` (no tuning UI).
///   - **Path B** (`YOLOEnd2EndDecoder`) thresholds the raw `[1, 300, 6]`
///     rows *in Swift*, so the confidence floor is a genuine runtime knob.
///     Conforming here is what lets `CoreMLDetector` pick up a conditional
///     `TunableDetector` conformance (see its `where Decoder:
///     TunableOutputDecoder` extension).
///
/// Modeling the knob on a decoder sub-protocol — rather than on
/// `CoreMLDetector` directly — keeps `CoreMLDetector` agnostic of *which*
/// knobs its decoder has: the detector's tunability is derived from the
/// decoder's, so a future path-B decoder with different knobs slots in by
/// conforming a richer sub-protocol without reshaping the detector.
///
/// **Rebuild, don't mutate.** Per the M4 hot-swap doctrine, a knob change
/// produces a *fresh* decoder via ``withConfidenceThreshold(_:)`` rather
/// than mutating in place — the detector that wraps it is likewise rebuilt.
/// `OutputDecoder` conformers are `Sendable` value types, so this is cheap.
public protocol TunableOutputDecoder: OutputDecoder {

    /// The current minimum confidence a decoded row must clear to become a
    /// `Detection`. In `[0, 1]`; a genuine class probability for YOLO.
    var confidenceThreshold: Float { get }

    /// The schema describing this decoder's tunable knob(s) — surfaced by
    /// the wrapping detector's `capabilities.tunableKnobs` and consumed by
    /// the capability-derived tuning UI. The confidence knob's `key` is
    /// ``confidenceThresholdKey``.
    static var settingSchema: SettingSchema { get }

    /// Build a fresh decoder identical to `self` but with a new confidence
    /// threshold (hot-swap-by-rebuild, per the M4 doctrine). The wrapping
    /// detector calls this in `apply(_:)` and rebuilds itself around the
    /// returned decoder.
    func withConfidenceThreshold(_ threshold: Float) -> Self
}

extension TunableOutputDecoder {
    /// Stable schema key for the confidence-threshold knob. Single source of
    /// truth shared by the schema, the detector's `apply(_:)` routing, and
    /// the `CoreMLDetectorSettings` value bridge.
    public static var confidenceThresholdKey: String { "confidenceThreshold" }
}
