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
}
