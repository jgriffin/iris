import CoreGraphics
import Vision

/// Path-A `OutputDecoder`: reads ready-made object observations straight off
/// a Vision-auto-decoded Core ML pipeline.
///
/// When the converted model is an Apple `NonMaximumSuppression` pipeline
/// (`coordinates` + `confidence` outputs — what `yolo export … nms=True`
/// produces), Vision decodes it for us into `RecognizedObjectObservation`
/// values. Each carries:
///
///   - `boundingBox: NormalizedRect` — `.cgRect` is the normalized `[0, 1]`,
///     **lower-left-origin** box, which is exactly `Detection.boundingBox`'s
///     convention. So there is **no** coordinate flip and **no** letterbox-
///     inverse math here: Vision already applied the inverse of the
///     `cropAndScaleAction` letterbox transform to put the box back in the
///     source frame's space.
///   - `labels: [ClassificationObservation]` — sorted best-first; we take
///     `.first` for the label + per-class confidence.
///   - `confidence: Float` — the whole-observation objectness/confidence.
///
/// **Class set comes baked in.** A `nms=True` Detect export bakes the label
/// list (the 80 COCO classes for stock YOLO) into the NMS stage, so the
/// `identifier` strings arrive populated; this decoder is reused verbatim by
/// *every* such export regardless of size or class set.
///
/// **Confidence is the per-class probability.** We stamp
/// `label.confidence` (the top class's probability) rather than
/// `observation.confidence` — for an object-detection pipeline the
/// best-label confidence is the meaningful per-detection probability that
/// `DetectorCapabilities.confidence == .probabilistic` advertises.
///
/// **Concurrency.** Stateless `struct` — `Sendable` for free.
public struct VisionObjectDecoder: OutputDecoder {

    public init() {}

    public func decode(
        _ observations: [any VisionObservation],
        frameSize _: CGSize,
        modelID: String
    ) throws -> [Detection] {
        var detections: [Detection] = []
        detections.reserveCapacity(observations.count)

        for case let object as RecognizedObjectObservation in observations {
            // `NormalizedRect.cgRect` is the normalized [0,1] lower-left-origin
            // box — matches `Detection.boundingBox` exactly. No flip, no
            // letterbox-inverse: Vision already mapped it back into the source
            // frame's coordinate space (it applies the inverse of the
            // `cropAndScaleAction` transform).
            let box = object.boundingBox.cgRect

            // `labels` is sorted best-first. Top label supplies both the class
            // string and the per-class confidence (the meaningful probability
            // for a detection pipeline).
            let top = object.labels.first
            let label = top?.identifier ?? ""
            let confidence = top?.confidence ?? object.confidence

            detections.append(
                Detection(
                    boundingBox: box,
                    label: label,
                    confidence: confidence,
                    // Path-A YOLO is a pure box detector — no keypoints,
                    // skeleton, or mask. A confidence-as-percent readout is
                    // the meaningful scalar (confidence is a real probability
                    // here, unlike the geometric Vision rectangle case).
                    readout: Self.confidenceReadout(confidence),
                    sourceModelID: modelID
                )
            )
        }

        return detections
    }

    /// Capability-honest readout for a probabilistic box detector: the
    /// detection confidence as an integer percent (e.g. `"87%"`). Distinct
    /// from the geometric detectors' readouts — here the confidence *is* a
    /// real probability, so surfacing it is honest.
    static func confidenceReadout(_ confidence: Float) -> Readout {
        let percent = Int((confidence * 100).rounded())
        return Readout(label: "confidence", text: "\(percent)%")
    }
}
