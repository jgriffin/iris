import CoreGraphics
import CoreML
import Vision

/// Path-B ``OutputDecoder`` for a YOLO **end2end** (one-to-one head) export:
/// decodes the raw `[1, 300, 6]` tensor a non-pipeline Core ML model returns,
/// with **no NMS** (the one-to-one head self-dedupes).
///
/// ## When this decoder applies
///
/// ultralytics forces `nms=False` on end2end models, so the converted YOLO26n
/// `.mlpackage` is **not** an Apple `NonMaximumSuppression` pipeline. Vision
/// can't auto-decode it; instead `CoreMLRequest` returns one
/// `CoreMLFeatureValueObservation` per model output, wrapping an
/// `MLMultiArray`. This export has a single output of shape `[1, 300, 6]`, so
/// we take the sole feature-value observation regardless of its name (the
/// converter named it `var_1441`; never hardcode that).
///
/// ## The 6 columns (empirically verified against the artifact)
///
/// Each of the 300 rows is `[x1, y1, x2, y2, confidence, classIndex]`,
/// confirmed by running the converted model on a real letterboxed frame and
/// logging the top rows:
///
///   - **Columns 0–3 are `xyxy`** — top-left `(x1, y1)` and bottom-right
///     `(x2, y2)` corners, **not** center+size (`xywh`). (`x1 < x2`,
///     `y1 < y2` on every confident row.)
///   - **Pixel coordinates in the model's 640×640 input space**, *not*
///     normalized `[0, 1]` (values range up to `640.0`).
///   - **Column 4 is the class confidence** in `[0, 1]` (a real probability).
///   - **Column 5 is the class index** into `labels` (e.g. `0.0` = `person`).
///
/// The model has **no embedded label list** (`METADATA keys: []`), so the
/// class index → string mapping is supplied externally via ``labels`` (see
/// ``COCOLabels/coco80`` for stock COCO).
///
/// ## Box mapping — the #1 correctness risk
///
/// `CoreMLDetector` runs with `cropAndScaleAction = .scaleToFit`, which
/// **letterboxes** the source frame into the model's 640² square (aspect
/// preserved, centered, padded). For a *path-A* recognized-object pipeline
/// Vision inverts that transform for us; for a **raw-tensor path-B** model it
/// does **not** — the 640-space pixel coords come back as-is. So this decoder
/// must invert the letterbox itself, using `frameSize` (the upright source
/// dimensions `W×H`):
///
///   1. `scale = min(640/W, 640/H)` — the letterbox scale.
///   2. Content rect inside the 640² canvas: size `(W·scale, H·scale)`,
///      centered, so pad offsets are `padX = (640 − W·scale)/2`,
///      `padY = (640 − H·scale)/2`.
///   3. Subtract the pad and divide by the scaled content size to land in
///      normalized `[0, 1]` of the *original* image:
///      `nx = (px − padX) / (W·scale)`, `ny = (py − padY) / (H·scale)`.
///   4. **Flip Y.** YOLO coords are **top-left origin**; `Detection.boundingBox`
///      is Vision-native **lower-left** normalized. So the box's normalized
///      top edge becomes its lower-left `minY` via `1 − ny`, and the rect is
///      rebuilt from the two flipped corners.
///
/// (Path A needed none of this — Vision inverse-mapped recognized-object
/// observations. Path B owns the whole inverse here.)
///
/// ## Tunability
///
/// Conforms to ``TunableOutputDecoder``: the confidence floor is a genuine
/// runtime knob (path-B thresholds in Swift, unlike path A's baked
/// thresholds). A knob change rebuilds the decoder via
/// ``withConfidenceThreshold(_:)`` (hot-swap doctrine); `CoreMLDetector` picks
/// up a conditional `TunableDetector` conformance from this.
///
/// **Concurrency.** Stateless `struct` (immutable `labels` + threshold) —
/// `Sendable` for free.
public struct YOLOEnd2EndDecoder: TunableOutputDecoder {

    /// Class-index → label mapping. Supplied externally because the export
    /// carries no embedded names (`METADATA keys: []`). Stock YOLO26n uses
    /// ``COCOLabels/coco80``; a custom model supplies its own list.
    public let labels: [String]

    /// Minimum class confidence (column 4) a row must clear to emit a
    /// `Detection`. Runtime-tunable — the path-B knob.
    public let confidenceThreshold: Float

    /// - Parameters:
    ///   - labels: Class-index → name mapping (e.g. ``COCOLabels/coco80``).
    ///   - confidenceThreshold: Minimum class confidence to keep a row.
    ///     Defaults to `0.25` — the ultralytics default detection confidence.
    public init(labels: [String], confidenceThreshold: Float = 0.25) {
        self.labels = labels
        self.confidenceThreshold = confidenceThreshold
    }

    // MARK: - TunableOutputDecoder

    /// Single-knob schema: the confidence floor. Worst-case tier is
    /// `.detector` — *lowering* the floor surfaces rows the decoder
    /// previously dropped, which the cache can't recover without re-running
    /// the model (raising is a strict subset and could be filter-tier; the
    /// per-transition downgrade lives in the detector's `apply(_:)`).
    public static var settingSchema: SettingSchema {
        SettingSchema(knobs: [
            SettingSchema.Knob(
                key: confidenceThresholdKey,
                label: "Min confidence",
                kind: .float(range: 0.0...1.0, step: 0.05, default: 0.25),
                tier: .detector
            )
        ])
    }

    public func withConfidenceThreshold(_ threshold: Float) -> YOLOEnd2EndDecoder {
        YOLOEnd2EndDecoder(labels: labels, confidenceThreshold: threshold)
    }

    // MARK: - OutputDecoder

    public func decode(
        _ observations: [any VisionObservation],
        frameSize: CGSize,
        modelID: String
    ) throws -> [Detection] {
        // The export has a single tensor output. Take the sole feature-value
        // observation regardless of its name — don't hardcode `var_1441` (a
        // converter-assigned identifier). On the MacOSX26.5 SDK the Sendable
        // `MLSendableFeatureValue` exposes the tensor via `shapedArrayValue(of:)`
        // (there is no `multiArrayValue` on the *sendable* wrapper); request a
        // `Float` shaped array — the dense, Sendable-clean read path.
        guard
            let feature = observations
                .lazy
                .compactMap({ $0 as? CoreMLFeatureValueObservation })
                .first,
            let tensor = feature.featureValue.shapedArrayValue(of: Float.self)
        else {
            // Not a raw-tensor observation — nothing this decoder can read.
            return []
        }

        // Expect [1, 300, 6]; tolerate a leading batch dim of 1.
        let shape = tensor.shape
        guard let columns = shape.last, columns >= 6, shape.count >= 2 else {
            return []
        }
        let rowCount = shape[shape.count - 2]

        // Letterbox-inverse parameters (see the type doc). `frameSize` is the
        // upright source size W×H; `modelInputSide` is the model's fixed
        // square (640 for YOLO26n) — the scaleToFit contract guarantees Vision
        // scaled the frame into that square, and the rows carry no input-size
        // field, so it's a named constant a different-resolution export can
        // override in one place.
        let modelSide = Self.modelInputSide
        let W = Double(frameSize.width)
        let H = Double(frameSize.height)
        guard W > 0, H > 0 else { return [] }

        let scale = min(modelSide / W, modelSide / H)
        let contentW = W * scale
        let contentH = H * scale
        let padX = (modelSide - contentW) / 2
        let padY = (modelSide - contentH) / 2

        var detections: [Detection] = []
        detections.reserveCapacity(min(rowCount, 32))

        // Read the tensor via its raw Float buffer, honoring the reported
        // strides (don't assume contiguous row-major). For [1, R, C] the
        // row stride and column stride are the last two stride entries;
        // element (r, c) lives at `r*rowStride + c*colStride` (the leading
        // batch index is 0).
        tensor.withUnsafeShapedBufferPointer { buffer, _, strides in
            let rowStride = strides[strides.count - 2]
            let colStride = strides[strides.count - 1]
            for r in 0..<rowCount {
                let base = r * rowStride
                let conf = buffer[base + 4 * colStride]
                guard conf >= confidenceThreshold else { continue }

                let x1 = Double(buffer[base + 0 * colStride])
                let y1 = Double(buffer[base + 1 * colStride])
                let x2 = Double(buffer[base + 2 * colStride])
                let y2 = Double(buffer[base + 3 * colStride])
                let classIndex = Int(buffer[base + 5 * colStride].rounded())

                guard let detection = makeDetection(
                    x1: x1, y1: y1, x2: x2, y2: y2,
                    confidence: conf,
                    classIndex: classIndex,
                    padX: padX, padY: padY,
                    contentW: contentW, contentH: contentH,
                    modelID: modelID
                ) else { continue }

                detections.append(detection)
            }
        }

        return detections
    }

    // MARK: - Box mapping

    /// Build one `Detection` from a raw 640-space `xyxy` row, inverting the
    /// letterbox and flipping Y. Returns `nil` for a degenerate/empty box.
    private func makeDetection(
        x1: Double, y1: Double, x2: Double, y2: Double,
        confidence: Float,
        classIndex: Int,
        padX: Double, padY: Double,
        contentW: Double, contentH: Double,
        modelID: String
    ) -> Detection? {
        guard contentW > 0, contentH > 0 else { return nil }

        // 1. Undo the letterbox: subtract centered pad, divide by scaled
        //    content size → normalized [0,1] in the ORIGINAL image,
        //    top-left origin (still YOLO's convention at this point).
        var nx1 = (x1 - padX) / contentW
        var nx2 = (x2 - padX) / contentW
        var nyTop = (y1 - padY) / contentH      // top edge (top-left origin)
        var nyBot = (y2 - padY) / contentH      // bottom edge

        // Clamp to [0,1] — boxes can poke a hair past the content rect.
        nx1 = nx1.clamped(to: 0...1)
        nx2 = nx2.clamped(to: 0...1)
        nyTop = nyTop.clamped(to: 0...1)
        nyBot = nyBot.clamped(to: 0...1)

        let width = nx2 - nx1
        guard width > 0 else { return nil }

        // 2. Flip Y to Vision-native lower-left origin. A top-left-origin
        //    top edge `nyTop` maps to a lower-left `maxY` of `1 - nyTop`; the
        //    bottom edge `nyBot` maps to `minY = 1 - nyBot`. Height is the
        //    span between them.
        let minY = 1 - nyBot
        let maxY = 1 - nyTop
        let height = maxY - minY
        guard height > 0 else { return nil }

        let box = CGRect(x: nx1, y: minY, width: width, height: height)

        // 3. Map class index → label (guard bounds).
        let label = (classIndex >= 0 && classIndex < labels.count)
            ? labels[classIndex]
            : ""

        return Detection(
            boundingBox: box,
            label: label,
            confidence: confidence,
            // Path-B YOLO is a pure box detector — no keypoints/skeleton.
            // Confidence is a real class probability, so a percent readout is
            // honest (mirrors VisionObjectDecoder).
            skeleton: nil,
            readout: Self.confidenceReadout(confidence),
            sourceModelID: modelID
        )
    }

    /// Capability-honest readout: the class confidence as an integer percent
    /// (e.g. `"87%"`). Mirrors `VisionObjectDecoder.confidenceReadout`.
    static func confidenceReadout(_ confidence: Float) -> Readout {
        let percent = Int((confidence * 100).rounded())
        return Readout(label: "confidence", text: "\(percent)%")
    }

    /// The model's fixed square input side. YOLO26n is 640². A different
    /// path-B export resolution overrides this one constant. (It is *not*
    /// derived from the tensor — the `[1, 300, 6]` rows carry no input-size
    /// field — and the scaleToFit contract guarantees Vision scaled into the
    /// model's own fixed input, which for this family is 640.)
    static let modelInputSide: Double = 640
}

// MARK: - Helpers

extension Comparable {
    /// Clamp to an inclusive range.
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
