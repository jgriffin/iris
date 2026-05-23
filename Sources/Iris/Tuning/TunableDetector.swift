/// `Detector` refinement that adds the tuning channel: a typed
/// `Settings` value + a per-transition classifier.
///
/// `TunableDetector` is the contract M4 hangs on: every detector that
/// wants to participate in the tuning UI conforms here, declares its
/// `Settings` type, and implements `apply(_:)` — the per-knob ×
/// direction classifier that returns the actual `ChangeTier` for *this*
/// specific transition.
///
/// **Why the classifier lives on the detector.** Only the detector
/// knows whether a knob transition crosses a model parameter or just a
/// display cutoff. The schema's static `tier` on each `Knob` is the
/// *worst-case* default — what the channel must assume when it can't
/// ask. `apply(_:)` is the cheap downgrade path: e.g. "raising the
/// minimum confidence cutoff is filter-tier, not detector-tier,
/// because the higher-confidence detections are a subset of what's
/// already in the cache."
///
/// **Concurrency.** Refines `Detector: Sendable`, so conformers inherit
/// the Sendable contract from the base protocol. Stateless conformers
/// stay `struct`; stateful conformers wrap mutable state per the
/// 2026-05-20 `Detector` stateful-conformer doctrine.
///
/// **Phase 1 scope.** Phase 1 ships the protocol shape + the first
/// concrete conformer (`VisionRectanglesDetector`). The
/// `ApplyResult.detector(rebuilt:)` payload is wired in Phase 2 —
/// Phase 1 conformers return `.detector(rebuilt: nil)` as a documented
/// placeholder. See `plans/features/M4.md`.
public protocol TunableDetector: Detector {

    /// Concrete settings type — one per detector family.
    associatedtype Settings: DetectorSettings

    /// Current settings snapshot. Mutating happens *outside* the
    /// detector (via the tuning model and hot-swap rebuild); the
    /// detector itself is a read-only window onto the value that
    /// produced it.
    var settings: Settings { get }

    /// Per-transition tier verdict. Given a single knob's transition,
    /// return the `ApplyResult` the channel should route on.
    ///
    /// The result may downgrade the schema's worst-case static tier
    /// (e.g. a `Knob` whose static tier is `.detector` may resolve to
    /// `.filter` for a specific raise-the-cutoff transition). It
    /// **must not** upgrade above the static tier — that would mean
    /// the channel's worst-case fallback is wrong, which is a bug in
    /// the schema, not a runtime decision.
    func apply(_ change: SettingChange) -> ApplyResult
}
