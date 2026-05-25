import Foundation

/// Tunable knob values for `VisionBodyPoseDetector`. Two honest knobs:
/// `detectsHands`, which forwards to `DetectHumanBodyPoseRequest.detectsHands`
/// and changes *what Vision returns* (detector-tier), and
/// `minimumJointConfidence`, a post-hoc per-joint confidence floor
/// (filter-tier).
///
/// **No whole-detection confidence knob.** Body pose carries confidence
/// *per joint* (`capabilities.confidence == .perElement`), not as a
/// whole-detection probability. `minimumJointConfidence` filters the
/// *individual joints* by their honest per-element confidence — it is the
/// direct analog of the rectangles quadrature filter (a post-hoc,
/// re-renderable view over the cached detector output), not a
/// whole-detection probability threshold.
///
/// **Label is a constant, not a knob.** Every emitted detection is labeled
/// `"person"`. The label is fixed here (`Self.label`) rather than surfaced
/// as a tunable, mirroring the body-pose domain (there is one class).
public struct VisionBodyPoseSettings: DetectorSettings {

    // MARK: - Keys

    /// Schema key for the `detectsHands` toggle. Single source of truth for
    /// the string used across the schema, the keyPath bridge, and the
    /// value accessors.
    public static let detectsHandsKey = "detectsHands"

    /// Schema key for the `minimumJointConfidence` slider. Single source of
    /// truth for the string used across the schema, the keyPath bridge, and
    /// the value accessors.
    public static let minimumJointConfidenceKey = "minimumJointConfidence"

    /// Fixed detection label for every body-pose detection. Constant, not a
    /// knob — there is one class (`person`).
    public static let label = "person"

    // MARK: - Knob values

    /// Whether Vision should also detect hand joints. Forwards to
    /// `DetectHumanBodyPoseRequest.detectsHands`. Changing it alters the
    /// set of joints Vision returns, so it is a detector-tier change.
    public var detectsHands: Bool

    /// Minimum per-joint confidence for a joint to be kept. Vision returns
    /// every joint it knows about — including undetected ones at ~(0,0)
    /// with ~0 confidence — so this floor drops the phantom joints that
    /// would otherwise scramble the skeleton (a stray corner dot, phantom
    /// edges, an inflated joint count, a bounding box pinned to the
    /// origin). A pure post-hoc per-joint filter over the cached
    /// detections, so it is filter-tier in both directions (see the
    /// detector's `apply(_:)`). Default `0.3` cleanly drops the ~0
    /// phantoms while keeping clearly-visible joints (typically 0.8+).
    public var minimumJointConfidence: Float

    // MARK: - Init

    public init(detectsHands: Bool = false, minimumJointConfidence: Float = 0.3) {
        self.detectsHands = detectsHands
        self.minimumJointConfidence = minimumJointConfidence
    }

    // MARK: - DetectorSettings

    /// KeyPath ↔ schema-key bridge. One entry per knob.
    public static func key(for keyPath: PartialKeyPath<Self>) -> String? {
        switch keyPath {
        case \Self.detectsHands: return detectsHandsKey
        case \Self.minimumJointConfidence: return minimumJointConfidenceKey
        default: return nil
        }
    }

    /// String-keyed value read for the capability-derived UI.
    public func value(forKey key: String) -> SettingChange.Value? {
        switch key {
        case Self.detectsHandsKey: return .toggle(detectsHands)
        case Self.minimumJointConfidenceKey: return .float(minimumJointConfidence)
        default: return nil
        }
    }

    /// String-keyed value write. Mismatched payload variants are dropped.
    public mutating func setValue(_ value: SettingChange.Value, forKey key: String) {
        switch (key, value) {
        case (Self.detectsHandsKey, .toggle(let v)): detectsHands = v
        case (Self.minimumJointConfidenceKey, .float(let v)): minimumJointConfidence = v
        default: break
        }
    }

    /// Two-knob schema. `detectsHands` is detector-tier — toggling it
    /// changes which joints Vision returns, which the cache can't recover
    /// without re-inference. `minimumJointConfidence` is filter-tier — it
    /// drops joints from the cached detections by their per-element
    /// confidence, re-renderable without re-inference (mirrors the
    /// rectangles quadrature filter).
    public static var schema: SettingSchema {
        SettingSchema(knobs: [
            SettingSchema.Knob(
                key: detectsHandsKey,
                label: "Detect hands",
                kind: .toggle(default: false),
                tier: .detector
            ),
            SettingSchema.Knob(
                key: minimumJointConfidenceKey,
                label: "Min joint confidence",
                kind: .float(range: 0.0...1.0, step: 0.05, default: 0.3),
                tier: .filter
            ),
        ])
    }
}
