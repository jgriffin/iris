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

        let detections = observations.compactMap { observation -> Detection? in
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

            // Capability-honest readout: the joint count. A pose has no
            // single probability worth showing (confidence is per-joint),
            // so the meaningful scalar is how many joints were located.
            let readout = Readout(label: "joints", text: "\(keypoints.count) joints")

            return Detection(
                boundingBox: bbox,
                label: VisionBodyPoseSettings.label,
                confidence: meanConfidence,
                keypoints: keypoints,
                skeleton: .humanBodyPose,
                readout: readout,
                sourceModelID: modelIdentifier
            )
        }
        // Apply the same settings-projection the filter-tier path uses, so
        // a fresh inference and a cached-then-filtered result agree exactly
        // (the per-joint confidence floor). This is what makes
        // `minimumJointConfidence` symmetric: the joint filter runs here on
        // fresh output *and* in `transform(for:)` on cached output, from one
        // definition. Mirrors `VisionRectanglesDetector.detect(in:)`.
        return Self.transform(for: settings)(detections)
    }

    // MARK: - TunableDetector

    /// Per-transition tier classifier.
    ///
    /// `detectsHands` changes which joints Vision returns — the cache can't
    /// recover the added/removed joints without re-inference, so it is
    /// detector-tier. `minimumJointConfidence` is a pure post-hoc per-joint
    /// filter over the cached detections (Vision always returns the full
    /// joint set; this floor drops the low-confidence ones in Swift), so it
    /// is filter-tier in both directions — symmetric and instant, mirroring
    /// the rectangles `quadratureToleranceDegrees` knob. A no-op transition
    /// (identical old/new) resolves to `.view`.
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
            // Preserve the current joint-confidence floor across the rebuild.
            return .detector(
                rebuilt: VisionBodyPoseDetector(
                    settings: VisionBodyPoseSettings(
                        detectsHands: new,
                        minimumJointConfidence: settings.minimumJointConfidence
                    )
                )
            )

        case VisionBodyPoseSettings.minimumJointConfidenceKey:
            guard case .float(let new) = change.newValue else {
                // Type-incompatible payload — worst-case detector-tier.
                return .detector(rebuilt: VisionBodyPoseDetector(settings: settings))
            }
            // Pure post-hoc per-joint filter. Vision always returns the full
            // joint set; tightening *or* loosening the floor just re-runs the
            // joint filter over the cached detections — filter-tier in both
            // directions, symmetric and instant. Mirrors rectangles'
            // `quadratureToleranceDegrees`.
            var newSettings = settings
            newSettings.minimumJointConfidence = new
            return .filter(transform: Self.transform(for: newSettings))

        default:
            // Unknown key — worst-case detector-tier with unchanged settings.
            return .detector(rebuilt: VisionBodyPoseDetector(settings: settings))
        }
    }

    // MARK: - Filter-tier transform builder

    /// Build the output-stage transform that projects `settings` onto a
    /// previously-cached `[Detection]`. The `.filter`-tier verdict for
    /// `minimumJointConfidence` returns this shape: re-run the current
    /// settings as a view over what the detector already produced.
    /// Centralizing the projection here keeps the `.filter` arm in
    /// `apply(_:)` one line and pins the predicate semantics in one place
    /// for tests. Mirrors `VisionRectanglesDetector.transform(for:)`.
    ///
    /// **What it does, per detection:**
    /// - Drops keypoints whose `confidence` is below
    ///   `settings.minimumJointConfidence`. Vision returns undetected joints
    ///   at ~(0,0) with ~0 confidence; the default `0.3` floor cleanly drops
    ///   those phantoms while keeping clearly-visible joints (typically
    ///   0.8+). Dropping the keypoints fixes the stray (0,0) dot, the
    ///   phantom skeleton edges (edges to dropped joints auto-skip in
    ///   `DetectionLayer.skeletonSegments`), the inflated joint count, and
    ///   the origin-pinned bounding box together.
    /// - Recomputes the axis-aligned bounding-box envelope from the
    ///   *remaining* keypoints.
    /// - Recomputes the `Readout` (`"\(n) joints"`) and the mean
    ///   `confidence` from the remaining keypoints.
    /// - Preserves `skeleton`, `label`, and `sourceModelID`.
    /// - Drops the whole detection if zero joints remain.
    ///
    /// Detections without keypoints (`nil` or `[]`) pass through unchanged
    /// — the filter can't judge joints a detection doesn't carry (e.g. a
    /// non-pose detection routed through the same transform).
    public static func transform(
        for settings: VisionBodyPoseSettings
    ) -> @Sendable ([Detection]) -> [Detection] {
        let floor = settings.minimumJointConfidence
        return { detections in
            detections.compactMap { detection -> Detection? in
                // No keypoints to judge — pass through unchanged.
                guard let keypoints = detection.keypoints else { return detection }

                let kept = keypoints.filter { $0.confidence >= floor }
                // Every joint dropped — drop the whole detection rather than
                // emit an empty, origin-pinned husk.
                guard !kept.isEmpty else { return nil }

                // Unchanged set — return as-is (avoids rebuilding the value).
                guard kept.count != keypoints.count else { return detection }

                // Recompute the envelope from the remaining joints.
                let xs = kept.map(\.position.x)
                let ys = kept.map(\.position.y)
                let minX = xs.min() ?? 0
                let maxX = xs.max() ?? 0
                let minY = ys.min() ?? 0
                let maxY = ys.max() ?? 0
                let bbox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

                // Recompute the mean confidence from the remaining joints.
                let meanConfidence =
                    kept.reduce(Float(0)) { $0 + $1.confidence } / Float(kept.count)

                // Recompute the joint-count readout from the remaining joints.
                let readout = Readout(label: "joints", text: "\(kept.count) joints")

                return Detection(
                    boundingBox: bbox,
                    label: detection.label,
                    confidence: meanConfidence,
                    keypoints: kept,
                    mask: detection.mask,
                    skeleton: detection.skeleton,
                    readout: readout,
                    sourceModelID: detection.sourceModelID
                )
            }
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
