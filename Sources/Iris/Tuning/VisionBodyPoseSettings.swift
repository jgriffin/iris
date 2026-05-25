import Foundation

/// Tunable knob values for `VisionBodyPoseDetector`. Deliberately minimal:
/// one honest knob, `detectsHands`, which forwards to
/// `DetectHumanBodyPoseRequest.detectsHands` and changes *what Vision
/// returns* — so it is a detector-tier change (see the detector's
/// `apply(_:)`).
///
/// **No confidence knob.** Body pose carries confidence *per joint*
/// (`capabilities.confidence == .perElement`), not as a whole-detection
/// probability. Per-joint confidence is stored on each
/// `Detection.Keypoint` and shown, but it is not a filter knob — the
/// minimal honest set is the single `detectsHands` toggle.
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

    /// Fixed detection label for every body-pose detection. Constant, not a
    /// knob — there is one class (`person`).
    public static let label = "person"

    // MARK: - Knob values

    /// Whether Vision should also detect hand joints. Forwards to
    /// `DetectHumanBodyPoseRequest.detectsHands`. Changing it alters the
    /// set of joints Vision returns, so it is a detector-tier change.
    public var detectsHands: Bool

    // MARK: - Init

    public init(detectsHands: Bool = false) {
        self.detectsHands = detectsHands
    }

    // MARK: - DetectorSettings

    /// KeyPath ↔ schema-key bridge. One entry for the single knob.
    public static func key(for keyPath: PartialKeyPath<Self>) -> String? {
        switch keyPath {
        case \Self.detectsHands: return detectsHandsKey
        default: return nil
        }
    }

    /// String-keyed value read for the capability-derived UI.
    public func value(forKey key: String) -> SettingChange.Value? {
        switch key {
        case Self.detectsHandsKey: return .toggle(detectsHands)
        default: return nil
        }
    }

    /// String-keyed value write. Mismatched payload variants are dropped.
    public mutating func setValue(_ value: SettingChange.Value, forKey key: String) {
        switch (key, value) {
        case (Self.detectsHandsKey, .toggle(let v)): detectsHands = v
        default: break
        }
    }

    /// Single-knob schema. `detectsHands` is detector-tier — toggling it
    /// changes which joints Vision returns, which the cache can't recover
    /// without re-inference.
    public static var schema: SettingSchema {
        SettingSchema(knobs: [
            SettingSchema.Knob(
                key: detectsHandsKey,
                label: "Detect hands",
                kind: .toggle(default: false),
                tier: .detector
            )
        ])
    }
}
