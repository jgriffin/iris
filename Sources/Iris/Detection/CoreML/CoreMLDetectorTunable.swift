import CoreGraphics

/// Tunable knob values for a path-B ``CoreMLDetector`` (one whose decoder is a
/// ``TunableOutputDecoder``). One knob: the **confidence threshold** the
/// decoder applies to the raw rows.
///
/// **Why a dedicated settings type.** `TunableDetector` requires a concrete
/// `Settings: DetectorSettings`. The schema, keyPath bridge, and string-keyed
/// value accessors all key off ``TunableOutputDecoder/confidenceThresholdKey``
/// so the decoder, the detector's `capabilities`, and `apply(_:)` share one
/// source of truth for the knob's identity.
///
/// **Path A has no settings.** A path-A `CoreMLDetector` (with
/// `VisionObjectDecoder`) is *not* `TunableDetector` — its thresholds are
/// baked at export — so it never constructs this type. Only the conditional
/// `where Decoder: TunableOutputDecoder` conformance uses it.
public struct CoreMLDetectorSettings: DetectorSettings {

    /// Minimum class confidence a decoded row must clear. Mirrors the
    /// decoder's `confidenceThreshold`; `[0, 1]`.
    public var confidenceThreshold: Float

    public init(confidenceThreshold: Float = 0.25) {
        self.confidenceThreshold = confidenceThreshold
    }

    // MARK: - DetectorSettings

    /// Single-knob schema, mirroring ``YOLOEnd2EndDecoder/settingSchema``.
    /// Lowering the floor surfaces rows the decoder previously dropped (the
    /// model must re-run), so the worst-case static tier is `.detector`; the
    /// detector's `apply(_:)` downgrades a *raise* to `.filter`.
    public static var schema: SettingSchema {
        SettingSchema(knobs: [
            SettingSchema.Knob(
                key: YOLOEnd2EndDecoder.confidenceThresholdKey,
                label: "Min confidence",
                kind: .float(range: 0.0...1.0, step: 0.05, default: 0.25),
                tier: .detector
            )
        ])
    }

    public static func key(for keyPath: PartialKeyPath<Self>) -> String? {
        switch keyPath {
        case \Self.confidenceThreshold: return YOLOEnd2EndDecoder.confidenceThresholdKey
        default: return nil
        }
    }

    public func value(forKey key: String) -> SettingChange.Value? {
        switch key {
        case YOLOEnd2EndDecoder.confidenceThresholdKey: return .float(confidenceThreshold)
        default: return nil
        }
    }

    public mutating func setValue(_ value: SettingChange.Value, forKey key: String) {
        switch (key, value) {
        case (YOLOEnd2EndDecoder.confidenceThresholdKey, .float(let v)):
            confidenceThreshold = v
        default:
            break
        }
    }
}

// MARK: - Conditional TunableDetector conformance

/// **Path-B tunability via conditional conformance.** A `CoreMLDetector`
/// becomes a `TunableDetector` *exactly when* its decoder carries a runtime
/// knob (`Decoder: TunableOutputDecoder`). Path A (`VisionObjectDecoder`) does
/// not conform, so its detector stays a plain `Detector` with no tuning UI —
/// honest about its baked thresholds.
///
/// **Hot-swap by rebuild.** Per the M4 doctrine a knob change produces a fresh
/// detector rather than mutating in place: `apply(_:)` builds a new decoder
/// via `decoder.withConfidenceThreshold(_:)` and rebuilds the detector around
/// the *same* compiled container (no model recompile). `settings` and
/// `capabilities.tunableKnobs` are read off the live decoder, so the three
/// stay consistent.
extension CoreMLDetector: TunableDetector where Decoder: TunableOutputDecoder {

    public var settings: CoreMLDetectorSettings {
        CoreMLDetectorSettings(confidenceThreshold: decoder.confidenceThreshold)
    }

    /// Per-transition tier verdict for the confidence knob.
    ///
    ///   - **No-op** (old == new) → `.view`.
    ///   - **Raise** the floor → `.filter`: the higher-confidence rows are a
    ///     strict subset of what the cache already holds, so a post-hoc
    ///     confidence filter over the cached `[Detection]` suffices — no
    ///     re-inference. (The decoder isn't even consulted; the filter is a
    ///     pure predicate.)
    ///   - **Lower** the floor → `.detector`: rows below the old floor were
    ///     never emitted and aren't in the cache, so the model must re-run.
    ///     Rebuild the detector around a decoder with the new threshold.
    public func apply(_ change: SettingChange) -> ApplyResult {
        guard change.key == YOLOEnd2EndDecoder.confidenceThresholdKey else {
            // Unknown key — worst-case rebuild with the current decoder.
            return .detector(rebuilt: self)
        }
        guard
            case .float(let old) = change.oldValue,
            case .float(let new) = change.newValue
        else {
            return .detector(rebuilt: self)
        }

        if new == old {
            return .view
        }
        if new > old {
            // Tighten: drop cached detections below the new floor. Pure
            // post-hoc filter — cache stays valid.
            return .filter(transform: { detections in
                detections.filter { $0.confidence >= new }
            })
        }
        // Loosen: surface previously-dropped rows → re-inference.
        let newDecoder = decoder.withConfidenceThreshold(new)
        let rebuilt = CoreMLDetector(
            container: container,
            decoder: newDecoder,
            modelIdentifier: modelIdentifier,
            availability: availability
        )
        return .detector(rebuilt: rebuilt)
    }
}
