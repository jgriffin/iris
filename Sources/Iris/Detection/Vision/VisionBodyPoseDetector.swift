import CoreGraphics
import Vision

/// `Detector` conformer wrapping Apple's Vision 2D human-body-pose request.
///
/// Detects people in a frame and reports each one as a `Detection` whose
/// `keypoints` are the body joints (nose, shoulders, elbows, …) and whose
/// `skeleton` is the canonical `Skeleton.humanBodyPose` edge topology — so
/// the overlay can stroke the limbs without holding any joint knowledge of
/// its own.
///
/// **API choice.** Uses the value-type Swift Vision API
/// (`DetectHumanBodyPoseRequest` / `HumanBodyPoseObservation`), matching how
/// `VisionRectanglesDetector` uses `DetectRectanglesRequest`. Both are
/// `Sendable` structs, and `perform(on:orientation:)` is natively
/// `async throws`, so the adapter crosses actor boundaries cleanly and is a
/// straight `await`.
///
/// **Joint names.** Each joint is keyed in the observation by a
/// `HumanBodyPoseObservation.JointName` whose `rawValue` is a stable camelCase
/// string (`"leftShoulder"`, `"nose"`, `"root"`, …). We stamp that
/// `rawValue` as the `Detection.Keypoint.name`, and `Skeleton.humanBodyPose`
/// references the same strings — so edges resolve by name regardless of
/// dictionary iteration order. (We use the dictionary *key*'s `rawValue`
/// rather than `Joint.jointName` to guarantee the exact string we expect.)
///
/// **Confidence semantics.** Body pose carries confidence *per joint*. Each
/// `Detection.Keypoint.confidence` holds the honest per-joint value;
/// `Detection.confidence` is the *mean* of the joints — a summary only, not a
/// probability. `capabilities.confidence` is `.perElement`, which tells the
/// overlay and the inspector not to read the flat field as certainty.
///
/// **Concurrency.** Stateless `struct` — `Sendable` for free, per the locked
/// `Detector` shape. A fresh request is constructed inside `detect(in:)`.
///
/// **Tuning.** Conforms to `TunableDetector` with
/// `Settings = VisionBodyPoseSettings`. One knob, `detectsHands`, which is a
/// detector-tier change (it alters the joints Vision returns).
public struct VisionBodyPoseDetector: TunableDetector {

    // MARK: - Settings

    /// Source-of-truth tunable knob values. Mutating happens *outside* the
    /// detector (hot-swap doctrine); read-only here.
    public let settings: VisionBodyPoseSettings

    public let availability: DetectorAvailability = .available

    public let modelIdentifier: String = "vision.bodyPose"

    // MARK: - Capabilities

    /// Honest capability descriptor for Vision body-pose detection.
    ///
    /// **Geometry: keypoints.** A body pose is a constellation of named
    /// joints carried in `Detection.keypoints`, with `skeleton` describing
    /// how they connect.
    ///
    /// **Confidence: `.perElement`.** The real signal lives on each
    /// `Detection.Keypoint.confidence`; `Detection.confidence` is only the
    /// mean. Declaring `.perElement` tells the overlay to draw no
    /// whole-detection confidence chip and the inspector to surface the
    /// per-joint values instead of the flat aggregate.
    ///
    /// **Knobs.** Reuse `VisionBodyPoseSettings.schema` verbatim — single
    /// source of truth.
    ///
    /// **Introspectable fields.** What a pose `Detection` carries: the
    /// joints (with per-element confidence), the envelope bounding box, and
    /// the fixed label.
    public var capabilities: DetectorCapabilities {
        DetectorCapabilities(
            geometryKinds: [.keypoints],
            confidence: .perElement,
            tunableKnobs: VisionBodyPoseSettings.schema,
            introspectableFields: [
                DetectorCapabilities.IntrospectableField(
                    key: "joints",
                    displayName: "Joints",
                    valueKind: .keypoints,
                    source: .keypoints
                ),
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
            ]
        )
    }

    // MARK: - Init

    /// Settings-shaped init. The hot-swap doctrine builds fresh instances
    /// this way after a detector-tier change.
    public init(settings: VisionBodyPoseSettings) {
        self.settings = settings
    }

    /// Convenience init.
    public init(detectsHands: Bool = false) {
        self.init(settings: VisionBodyPoseSettings(detectsHands: detectsHands))
    }

    // MARK: - Detector

    /// No-op. Vision's built-in requests don't expose an explicit prewarm
    /// hook; running a throwaway request against a synthetic buffer here
    /// would shift the first-frame cost, not remove it. Callers that care
    /// about first-frame latency should run `detect(in:)` against a
    /// representative frame at warm-up time. (Mirrors
    /// `VisionRectanglesDetector.prewarm()`.)
    public func prewarm() async {
        // intentionally empty
    }

    public func detect(in frame: Frame) async throws -> [Detection] {
        var request = DetectHumanBodyPoseRequest()
        request.detectsHands = settings.detectsHands

        let observations = try await request.perform(
            on: frame.pixelBuffer,
            orientation: frame.orientation
        )

        return observations.compactMap { observation -> Detection? in
            let joints = observation.allJoints()
            guard !joints.isEmpty else { return nil }

            // Stamp the dictionary key's `rawValue` (a stable camelCase
            // string) as the keypoint name, matching `Skeleton.humanBodyPose`
            // edge names. Joint location is in Vision-native normalized
            // (bottom-left origin) coordinates; convert the same way the
            // rectangles adapter does (`.cgPoint`) — the centralized Y-flip
            // lives in the overlay's converter, not here.
            let keypoints: [Detection.Keypoint] = joints.map { name, joint in
                Detection.Keypoint(
                    name: name.rawValue,
                    position: joint.location.cgPoint,
                    confidence: joint.confidence
                )
            }

            // Axis-aligned envelope of the joint positions.
            let xs = keypoints.map(\.position.x)
            let ys = keypoints.map(\.position.y)
            let minX = xs.min() ?? 0
            let maxX = xs.max() ?? 0
            let minY = ys.min() ?? 0
            let maxY = ys.max() ?? 0
            let bbox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

            // Mean of the per-joint confidences — a summary only. The honest
            // per-element confidence lives on each keypoint
            // (`capabilities.confidence == .perElement`).
            let meanConfidence =
                keypoints.isEmpty
                ? 0
                : keypoints.reduce(Float(0)) { $0 + $1.confidence } / Float(keypoints.count)

            return Detection(
                boundingBox: bbox,
                label: VisionBodyPoseSettings.label,
                confidence: meanConfidence,
                keypoints: keypoints,
                skeleton: .humanBodyPose,
                sourceModelID: modelIdentifier
            )
        }
    }

    // MARK: - TunableDetector

    /// Per-transition tier classifier. The sole knob, `detectsHands`,
    /// changes which joints Vision returns — the cache can't recover the
    /// added/removed joints without re-inference, so it is detector-tier.
    /// A no-op transition (identical old/new) resolves to `.view`.
    public func apply(_ change: SettingChange) -> ApplyResult {
        if change.oldValue == change.newValue {
            return .view
        }

        switch change.key {
        case VisionBodyPoseSettings.detectsHandsKey:
            guard case .toggle(let new) = change.newValue else {
                // Type-incompatible payload — rebuild with current settings.
                return .detector(rebuilt: VisionBodyPoseDetector(settings: settings))
            }
            return .detector(
                rebuilt: VisionBodyPoseDetector(
                    settings: VisionBodyPoseSettings(detectsHands: new)
                )
            )

        default:
            // Unknown key — worst-case detector-tier with unchanged settings.
            return .detector(rebuilt: VisionBodyPoseDetector(settings: settings))
        }
    }
}

// MARK: - Canonical body-pose skeleton

extension Skeleton {

    /// The canonical 2D human-body-pose skeleton, defined here (with the
    /// detector that produces it) because the joint topology is body-pose
    /// domain knowledge, not a property of the generic `Skeleton` type or
    /// the overlay.
    ///
    /// Edge names are the `HumanBodyPoseObservation.JointName` `rawValue`s
    /// that `VisionBodyPoseDetector` stamps onto `Detection.keypoints`.
    /// Every joint Vision's body-pose request provides is connected:
    ///
    ///   - **head/face:** nose–leftEye, nose–rightEye, leftEye–leftEar,
    ///     rightEye–rightEar, neck–nose
    ///   - **arms:** neck–leftShoulder, leftShoulder–leftElbow,
    ///     leftElbow–leftWrist; neck–rightShoulder,
    ///     rightShoulder–rightElbow, rightElbow–rightWrist
    ///   - **torso/legs:** neck–root, root–leftHip, leftHip–leftKnee,
    ///     leftKnee–leftAnkle; root–rightHip, rightHip–rightKnee,
    ///     rightKnee–rightAnkle
    ///
    /// Edges whose endpoints aren't both present on a given detection are
    /// skipped at draw time (`DetectionLayer.skeletonSegments(of:)`), so a
    /// partially-occluded pose still renders the limbs it does have.
    public static let humanBodyPose = Skeleton(edges: [
        // head / face
        Edge(from: "nose", to: "leftEye"),
        Edge(from: "nose", to: "rightEye"),
        Edge(from: "leftEye", to: "leftEar"),
        Edge(from: "rightEye", to: "rightEar"),
        Edge(from: "neck", to: "nose"),
        // arms
        Edge(from: "neck", to: "leftShoulder"),
        Edge(from: "leftShoulder", to: "leftElbow"),
        Edge(from: "leftElbow", to: "leftWrist"),
        Edge(from: "neck", to: "rightShoulder"),
        Edge(from: "rightShoulder", to: "rightElbow"),
        Edge(from: "rightElbow", to: "rightWrist"),
        // torso / legs
        Edge(from: "neck", to: "root"),
        Edge(from: "root", to: "leftHip"),
        Edge(from: "leftHip", to: "leftKnee"),
        Edge(from: "leftKnee", to: "leftAnkle"),
        Edge(from: "root", to: "rightHip"),
        Edge(from: "rightHip", to: "rightKnee"),
        Edge(from: "rightKnee", to: "rightAnkle"),
    ])
}
