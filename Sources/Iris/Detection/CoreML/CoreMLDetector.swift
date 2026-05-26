import CoreGraphics
import CoreML
import Vision

/// `Detector` conformer that runs a converted Core ML model through Vision's
/// `CoreMLRequest`, decoding its output via a pluggable ``OutputDecoder``.
///
/// **One detector, a swappable decoder.** The decisive fork between model
/// families is *how the output is decoded* (see ``OutputDecoder`` for the
/// path-A / path-B distinction). `CoreMLDetector` owns everything that's the
/// same regardless of that fork — loading the compiled model, wrapping it in a
/// `CoreMLModelContainer`, setting the aspect-preserving crop/scale, and
/// running `CoreMLRequest.perform(on:orientation:)` — and delegates the
/// model-specific decode to its `Decoder`. M6·P2 ships only
/// ``VisionObjectDecoder`` (path A, YOLOv12n); P3 adds the path-B
/// `YOLOEnd2EndDecoder` through the same seam with no change here.
///
/// **Crop/scale.** `cropAndScaleAction = .scaleToFit` is the aspect-preserving
/// letterbox that matches how YOLO models are trained. Vision reads the
/// model's fixed input size from the model itself — **nothing here hardcodes
/// 640** — and applies the *inverse* of the letterbox transform to the boxes
/// it returns, so a path-A decoder gets boxes already in the source frame's
/// normalized space.
///
/// **Thresholds (P2).** Path-A models bake their IoU/confidence thresholds at
/// export time, so P2 carries no runtime threshold knobs — it conforms to
/// `Detector` only, **not** `TunableDetector`. Runtime-tunable thresholds are
/// the M6·P3 question (they'd force a path-B decoder + Swift NMS).
///
/// **Concurrency.** A `final class` holding an immutable
/// `CoreMLModelContainer` (a `Sendable` Vision value) + a `Sendable` decoder,
/// so it is `Sendable`. A fresh `CoreMLRequest` is constructed per
/// `detect(in:)` call, so the detector holds no mutable per-frame state.
public final class CoreMLDetector<Decoder: OutputDecoder>: Detector {

    /// The Vision container wrapping the compiled `MLModel`. Built once at
    /// construction; immutable thereafter.
    private let container: CoreMLModelContainer

    /// The output decoder. Stateless; turns the request's observations into
    /// `[Detection]`.
    private let decoder: Decoder

    public let modelIdentifier: String

    public let availability: DetectorAvailability

    // MARK: - Capabilities

    /// Honest capability descriptor for a path-A YOLO box detector.
    ///
    /// **Geometry: box.** A `nms=True` Detect export yields axis-aligned
    /// boxes only — no keypoints, quad, or mask.
    ///
    /// **Confidence: `.probabilistic`.** Unlike the geometric Vision
    /// rectangle detector, a YOLO detection's confidence is a genuine
    /// class probability in `[0, 1]`, so it may honestly be shown as a chip.
    ///
    /// **Knobs: none (P2).** Path-A thresholds are baked at export; the
    /// schema is empty. Runtime tuning is the P3 question.
    ///
    /// **Introspectable fields.** What a box detection carries: the bounding
    /// box, the class label, and the confidence.
    public var capabilities: DetectorCapabilities {
        DetectorCapabilities(
            geometryKinds: [.box],
            confidence: .probabilistic,
            tunableKnobs: SettingSchema(knobs: []),
            introspectableFields: [
                DetectorCapabilities.IntrospectableField(
                    key: "boundingBox",
                    displayName: "Bounding box",
                    valueKind: .boundingBox,
                    source: .boundingBox
                ),
                DetectorCapabilities.IntrospectableField(
                    key: "label",
                    displayName: "Label",
                    valueKind: .label,
                    source: .label
                ),
                DetectorCapabilities.IntrospectableField(
                    key: "confidence",
                    displayName: "Confidence",
                    valueKind: .scalar,
                    source: .confidence
                ),
            ]
        )
    }

    // MARK: - Init

    /// Build a detector around an already-compiled `MLModel`.
    ///
    /// Use ``CoreMLModelLoading`` to compile an `.mlpackage` to a model at
    /// runtime; this initializer takes the loaded model so the loading policy
    /// (where the bundle lives, which `computeUnits`) stays a caller concern.
    ///
    /// - Parameters:
    ///   - model: The compiled Core ML model (path-A NMS pipeline for the P2
    ///     `VisionObjectDecoder`).
    ///   - decoder: The output decoder for this model's export shape.
    ///   - modelIdentifier: Stable id stamped onto every `Detection`.
    public init(
        model: MLModel,
        decoder: Decoder,
        modelIdentifier: String
    ) throws {
        self.container = try CoreMLModelContainer(model: model)
        self.decoder = decoder
        self.modelIdentifier = modelIdentifier
        self.availability = .available
    }

    // MARK: - Detector

    /// No-op. `CoreMLRequest` doesn't expose an explicit prewarm hook, and the
    /// model is already compiled + container-wrapped at construction. Callers
    /// that care about first-frame latency should run `detect(in:)` against a
    /// representative frame at warm-up time (mirrors the Vision detectors).
    public func prewarm() async {
        // intentionally empty
    }

    public func detect(in frame: Frame) async throws -> [Detection] {
        var request = CoreMLRequest(model: container)
        // Aspect-preserving letterbox — matches YOLO training. Vision applies
        // the INVERSE transform to returned boxes, so a path-A decoder sees
        // boxes already in the source frame's normalized space. Never hardcode
        // the input size; Vision reads it from the model.
        request.cropAndScaleAction = .scaleToFit

        let observations = try await request.perform(
            on: frame.pixelBuffer,
            orientation: frame.orientation
        )

        return try decoder.decode(
            observations,
            frameSize: frame.dimensions,
            modelID: modelIdentifier
        )
    }
}
