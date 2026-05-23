import Foundation

/// Marker + schema-exporting protocol for detector-family settings types.
///
/// `DetectorSettings` is the *concrete* surface of the M4 tuning channel
/// (the schema export is the parallel read-only view, accessible via
/// `Self.schema`). Detector-family settings types — one per detector
/// family that shares anatomy — conform here.
///
/// **Why a static schema.** The schema enumerates every knob the
/// concrete type carries, with its *worst-case* `ChangeTier`. The
/// detector itself may downgrade a *specific* transition (e.g. raising
/// a confidence cutoff is filter-tier even when the schema's static
/// tier is `.detector`) at apply-time via `TunableDetector.apply(_:)`.
/// The schema is static because the knobs themselves are compile-time
/// fixed for a given settings type; only the values vary.
///
/// **Schema-derivation strategy (M4 Phase 1).** Hand-rolled — each
/// settings type defines its `static var schema` literally. The drift
/// risk between the stored properties and the schema's `Knob` list is
/// real but small at one settings type; revisit (macro? introspection?)
/// when a third concrete type lands. See `plans/features/M4.md` "Risks".
public protocol DetectorSettings: Sendable {
    /// Compile-time enumeration of every tunable knob on this settings
    /// type. The schema is the channel between the concrete type and
    /// generic UIs / serialization / change-routing.
    static var schema: SettingSchema { get }

    /// Map a `PartialKeyPath<Self>` (the typed mutation surface
    /// `TuningModel.update(_:to:)` uses) to its schema `key` string.
    ///
    /// **Why hand-rolled.** Swift's `_kvcKeyPathString` is `nil` for
    /// plain stored properties on Swift `struct`s (KVC interop
    /// requires `@objc`, which `Sendable` Swift settings types don't
    /// adopt). The tuning channel keys changes by the schema's
    /// `Knob.key`, so each conformer needs an explicit
    /// keyPath-to-key bridge. One small table per settings type —
    /// drift risk identical to the static `schema` itself, and
    /// `DetectorSettingsTests`-style audits pin both.
    ///
    /// Returns `nil` for keyPaths that don't map to a schema knob
    /// (e.g. derived computed properties, future additions before
    /// the bridge is updated). `TuningModel.update(_:to:)` then
    /// emits a `SettingChange` with an empty key, which the
    /// classifier handles via the worst-case fallback arm.
    static func key(for keyPath: PartialKeyPath<Self>) -> String?
}

extension DetectorSettings {
    /// Default implementation: no keyPath knows its key. Conformers
    /// override to provide the mapping. The default exists so a
    /// settings type that hasn't yet been wired for `TuningModel`-
    /// driven mutation still satisfies the protocol — the
    /// `TuningModel` falls back to the empty-key path described above.
    public static func key(for _: PartialKeyPath<Self>) -> String? {
        nil
    }
}

// MARK: - SettingSchema

/// Compile-time enumeration of the knobs a `DetectorSettings` type
/// carries. Built once per settings type (`static var schema`) and
/// consumed by the tuning channel + any generic UI that wants to render
/// arbitrary detector settings without compile-time knowledge.
public struct SettingSchema: Sendable {

    /// Every tunable knob on the parent settings type, in display order.
    public let knobs: [Knob]

    public init(knobs: [Knob]) {
        self.knobs = knobs
    }

    /// A single tunable knob — one property on the concrete settings
    /// type, surfaced for generic consumers.
    public struct Knob: Sendable {

        /// Stable identifier matching the property name on the concrete
        /// settings type. Used as the lookup key in `SettingChange`.
        public let key: String

        /// Human-readable label for UI rendering.
        public let label: String

        /// Type + bounds + default for this knob.
        public let kind: SettingKind

        /// Worst-case change tier — what the channel must assume when
        /// it can't ask the detector for a per-transition verdict.
        /// `TunableDetector.apply(_:)` may downgrade a specific
        /// transition (e.g. raising a confidence cutoff is filter-tier
        /// even when this static tier is `.detector`).
        public let tier: ChangeTier

        public init(
            key: String,
            label: String,
            kind: SettingKind,
            tier: ChangeTier
        ) {
            self.key = key
            self.label = label
            self.kind = kind
            self.tier = tier
        }
    }
}

// MARK: - SettingKind

/// Type + bounds + default for a single knob. Covers the four shapes a
/// detector knob can take: continuous `Float`, discrete `Int`, boolean
/// toggle, and multi-select over a fixed set of options (e.g. class
/// allow-list for an object detector).
public enum SettingKind: Sendable {
    /// Continuous floating-point knob with inclusive `range` and snap
    /// `step` (the resolution UIs should use for sliders / steppers).
    case float(range: ClosedRange<Float>, step: Float, default: Float)

    /// Discrete integer knob. `step` is typically `1` but exposed so
    /// e.g. `maximumObservations` can step in units of 5 if desired.
    case int(range: ClosedRange<Int>, step: Int, default: Int)

    /// Boolean toggle.
    case toggle(default: Bool)

    /// Multi-select over a fixed set of options — e.g. a class
    /// allow-list. `options` is the full universe; `default` is the
    /// initial subset.
    case multiSelect(options: [String], default: Set<String>)
}

// MARK: - ChangeTier

/// Three-tier change taxonomy from `plans/features/M4.md`. Misclassifying
/// a `.detector` change as `.filter` silently produces wrong results
/// (the cache holds answers produced under the *old* knob value, never
/// re-run); misclassifying a `.filter` as `.detector` only costs
/// latency. The schema's static tier therefore defaults to the
/// *worst-case* (`.detector`) and the per-transition classifier on
/// `TunableDetector.apply(_:)` may downgrade.
public enum ChangeTier: Sendable, Hashable {
    /// Re-render only. Detector unchanged. Cache unchanged. The
    /// overlay re-draws on its own tick.
    case view

    /// Pre-overlay filter pass. Detector unchanged. Cache unchanged.
    /// One pass over a `[Detection]` between cache lookup and overlay.
    case filter

    /// Detector rebuilt per the 2026-05-20 hot-swap doctrine. Cache
    /// entries produced under the old settings become stale.
    case detector
}

// MARK: - SettingChange

/// A single knob transition. Carries the knob key + the old and new
/// values as type-erased payloads so the channel can be uniform across
/// `Float` / `Int` / `Bool` / `Set<String>` knobs.
///
/// Construction is intentionally narrow — callers go through
/// `SettingChange.float(key:from:to:)` (and siblings) rather than the
/// memberwise init so the payload variant is forced to line up with
/// the knob's `SettingKind`.
public struct SettingChange: Sendable {

    public let key: String
    public let oldValue: Value
    public let newValue: Value

    /// Type-erased value payload. One variant per `SettingKind`.
    public enum Value: Sendable, Equatable {
        case float(Float)
        case int(Int)
        case toggle(Bool)
        case multiSelect(Set<String>)
    }

    public init(key: String, oldValue: Value, newValue: Value) {
        self.key = key
        self.oldValue = oldValue
        self.newValue = newValue
    }

    /// Convenience builder for a continuous-float knob transition.
    public static func float(key: String, from old: Float, to new: Float) -> Self {
        SettingChange(key: key, oldValue: .float(old), newValue: .float(new))
    }

    /// Convenience builder for a discrete-int knob transition.
    public static func int(key: String, from old: Int, to new: Int) -> Self {
        SettingChange(key: key, oldValue: .int(old), newValue: .int(new))
    }

    /// Convenience builder for a boolean-toggle knob transition.
    public static func toggle(key: String, from old: Bool, to new: Bool) -> Self {
        SettingChange(key: key, oldValue: .toggle(old), newValue: .toggle(new))
    }

    /// Convenience builder for a multi-select knob transition.
    public static func multiSelect(
        key: String,
        from old: Set<String>,
        to new: Set<String>
    ) -> Self {
        SettingChange(
            key: key,
            oldValue: .multiSelect(old),
            newValue: .multiSelect(new)
        )
    }
}

// MARK: - ApplyResult

/// The per-transition tier verdict returned by `TunableDetector.apply(_:)`.
///
/// **API shape note.** The `.detector` arm carries an `(any Detector)?`
/// payload — the rebuilt detector instance per the hot-swap doctrine.
/// In M4 Phase 1 this payload is always `nil` (the channel isn't wired
/// yet); Phase 2's `DetectorPipeline` integration is what actually
/// constructs the rebuilt detector and threads it through. The shape
/// is locked here so Phase 2's wiring is a *fill-in*, not a
/// source-breaking change.
public enum ApplyResult: Sendable {

    /// View-tier — re-render only. No filter pass, no rebuild.
    case view

    /// Filter-tier — install a pre-overlay filter pass for this
    /// transition. Cache stays valid; detector unchanged.
    case filter

    /// Detector-tier — rebuild the detector and invalidate cache
    /// entries produced under the old settings.
    ///
    /// `rebuilt` is the fresh detector instance produced by applying
    /// the new knob value, per the 2026-05-20 hot-swap doctrine.
    /// `nil` is a Phase 1 placeholder while the pipeline wiring is
    /// still pending.
    case detector(rebuilt: (any Detector)?)

    /// The tier the channel should assume from this result. Strips the
    /// rebuilt-detector payload — useful for routing logic that
    /// doesn't care about the payload, and for test assertions.
    public var tier: ChangeTier {
        switch self {
        case .view: .view
        case .filter: .filter
        case .detector: .detector
        }
    }
}
