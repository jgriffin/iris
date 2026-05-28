import CoreGraphics

/// A single detection emitted by a `Detector`.
///
/// `Detection` is the value type all downstream code (overlays, dataset
/// capture, telemetry) consumes. It is intentionally agnostic of which
/// backend produced it — Vision, Core ML, Foundation Models, or a Mock — so
/// the rendering and storage paths never branch on producer.
///
/// **Coordinate convention.** `boundingBox` is **normalized** to `[0, 1]` in
/// the source frame's coordinate space (per the prior-projects
/// recommendation to store normalized values and denormalize only at
/// render time). The origin convention is Vision-native (bottom-left); the
/// centralized Y-flip lives in `IrisOverlay`'s
/// `NormalizedGeometryConverting` backends, not here.
///
/// **Value-type guarantee.** All fields are plain Swift value types. If a
/// future backend produces an observation type that isn't `Sendable`-clean,
/// the adapter is responsible for unwrapping it into this struct rather
/// than smuggling a non-Sendable reference through.
/// **Serialization (M7·P1).** `Detection` conforms to `Codable` via Swift's
/// synthesized conformance. The choice between direct conformance and a
/// separate `DetectionRecord` DTO was settled in favor of direct conformance:
/// every field is a plain value type with synthesizable `Codable` (`CGRect`,
/// `String`, `Float`, and the nested `Keypoint` / `Mask` / `Skeleton` /
/// `Readout` value types), and the self-describing `skeleton` / `readout`
/// fields are flat structs with no polymorphism — the thing that would
/// otherwise force a DTO. A DTO would duplicate the whole field set for zero
/// schema benefit. Synthesis requires the conformance to be declared on the
/// type itself (not a cross-file extension), so it lives here; the rationale
/// note lives next to its consumer in `Sources/Iris/Dataset/`.
public struct Detection: Sendable, Hashable, Codable {

    /// Normalized bounding box in `[0, 1]` source-frame coordinates,
    /// Vision-native (bottom-left) origin.
    public let boundingBox: CGRect

    /// Human- or machine-readable class label (e.g., `"face"`, `"person"`,
    /// `"ball"`). Empty string is permitted for class-agnostic detectors.
    public let label: String

    /// Detector-reported confidence in `[0, 1]`. `1.0` for detectors that
    /// don't emit confidences (e.g., a mock or a face-rectangle pass).
    public let confidence: Float

    /// Optional keypoints in the same normalized coordinate space as
    /// `boundingBox`. Empty array and `nil` mean different things: `nil`
    /// is "this detector doesn't produce keypoints"; `[]` is "it does, but
    /// found none on this detection."
    public let keypoints: [Keypoint]?

    /// Optional segmentation mask.
    ///
    /// TODO M2+: Mask payload shape is not yet locked. Candidates: a
    /// normalized polyline, an `MLMultiArray` wrapper, or an opaque value
    /// type backed by a per-pixel buffer. Phase 3's first segmentation
    /// adapter will pin this down. For now this is a placeholder `Mask`
    /// value-type so the field exists in the schema without committing
    /// to a representation.
    public let mask: Mask?

    /// Identifier of the model that produced this detection. Flows
    /// through to dataset sidecars and telemetry. Should match the
    /// producing `Detector`'s `modelIdentifier`.
    public let sourceModelID: String

    /// Skeleton edge topology for keypoint detections (pose) — the named
    /// connections the overlay strokes between `keypoints`. `nil` for
    /// box / quad detections, which carry no skeleton. Self-describing:
    /// the detector stamps the topology, so the overlay draws whatever
    /// edges a detection carries without holding any joint knowledge.
    public let skeleton: Skeleton?

    /// Capability-honest numeric readout the producing detector stamps for
    /// display — the meaningful number for THAT detector (a rectangle's
    /// aspect ratio, a pose's joint count), never a fabricated probability.
    /// Self-describing, exactly like `skeleton`: the detector computes the
    /// metric, and the overlay's default label formatter surfaces it
    /// generically without knowing which detector produced it. `nil` for
    /// detectors that have no meaningful scalar to report.
    public let readout: Readout?

    public init(
        boundingBox: CGRect,
        label: String,
        confidence: Float,
        keypoints: [Keypoint]? = nil,
        mask: Mask? = nil,
        skeleton: Skeleton? = nil,
        readout: Readout? = nil,
        sourceModelID: String
    ) {
        self.boundingBox = boundingBox
        self.label = label
        self.confidence = confidence
        self.keypoints = keypoints
        self.mask = mask
        self.skeleton = skeleton
        self.readout = readout
        self.sourceModelID = sourceModelID
    }
}

extension Detection {

    /// A single labeled point in the same normalized coordinate space as
    /// the enclosing `Detection.boundingBox`.
    public struct Keypoint: Sendable, Hashable, Codable {
        /// Joint / landmark identifier (e.g., `"left_shoulder"`, `"nose"`).
        public let name: String
        /// Normalized `[0, 1]` position, Vision-native origin.
        public let position: CGPoint
        /// Per-keypoint confidence in `[0, 1]`.
        public let confidence: Float

        public init(name: String, position: CGPoint, confidence: Float) {
            self.name = name
            self.position = position
            self.confidence = confidence
        }
    }

    /// Placeholder segmentation-mask payload. See `Detection.mask` for the
    /// open `TODO M2+:` on the eventual shape.
    public struct Mask: Sendable, Hashable, Codable {
        /// Width of the mask in pixels.
        public let width: Int
        /// Height of the mask in pixels.
        public let height: Int

        // TODO M2+: pixel payload. Likely either `[UInt8]` (per-pixel class
        // ID) or `[Float]` (per-pixel logit / probability). Held off until
        // Phase 3 introduces the first segmentation backend so we don't
        // overcommit to a representation that the first real producer
        // would force us to refactor.

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }
}
