/// Per-frame detection backend.
///
/// `Detector` is the single seam between Iris's frame pipeline and any
/// detection backend — Vision, Core ML, Foundation Models, or a mock. New
/// backends slot in by conforming; the rest of the pipeline never branches
/// on which one is in use.
///
/// **Concurrency contract.** `Detector` is `Sendable`-only by design. The
/// protocol declares no isolation; conformers choose:
///
/// - **Stateless** conformers are plain `struct` — `Sendable` for free.
/// - **Stateful** conformers (trajectory tracking, anything reusing a
///   request across frames) wrap their mutable state in an internal
///   `actor` and present a `Sendable` `struct`/`final class` facade. The
///   *protocol* stays stateless-looking; isolation lives inside the
///   conformer.
///
/// This matches the locked decision in `plans/DECISIONS.md` — *"Hot-swap by
/// replacing the instance"* — and PFM's `LanguageModelBackend` shape (which
/// this protocol is derived from).
///
/// **Hot-swap.** To change models or detectors mid-session, construct a
/// fresh instance and replace the reference. Never reach into a running
/// detector to mutate its model.
public protocol Detector: Sendable {

    /// Whether this detector is ready to run on the current device.
    /// Detectors that require entitlements, OS features, or downloaded
    /// model assets surface their readiness here so callers can branch
    /// on it before driving frames in.
    var availability: DetectorAvailability { get }

    /// Stable identifier for the model behind this detector. Used in
    /// telemetry and `Detection.sourceModelID` so downstream consumers
    /// can attribute detections to the exact producer.
    var modelIdentifier: String { get }

    /// Warm the inference pipeline (compile models, allocate scratch
    /// buffers, run a throwaway pass against a synthetic input). Calling
    /// `prewarm()` is optional — a `Detector` is required to handle the
    /// first call to `detect(in:)` correctly without it — but recommended
    /// once before driving live frames in, to avoid first-frame stalls.
    func prewarm() async

    /// Run detection over one frame. Returns `[]` when the detector ran
    /// successfully and found nothing; throws when the run itself fails.
    /// "No detector ran" is represented by *not calling this method*, not
    /// by `nil` — empty vs absent are distinct states downstream.
    func detect(in frame: Frame) async throws -> [Detection]
}

/// Readiness state for a `Detector`. Mirrors PFM's
/// `LanguageModelBackend.Availability` so the call-site idiom is the same
/// whether you're branching on a detection backend or an LM backend.
///
/// Declared as a top-level type rather than `Detector.Availability`
/// because Swift forbids nested types in protocol extensions. The
/// swift-ecosystem recommendation reads `Detector.Availability` in prose;
/// the in-language spelling is `DetectorAvailability`.
public enum DetectorAvailability: Sendable, Hashable {
    /// Ready to run.
    case available
    /// The host device cannot run this detector (e.g., a Neural
    /// Engine-only model on a device without one, or an entitlement
    /// gate the app doesn't hold).
    case deviceNotEligible
    /// The device is eligible, but the model itself isn't on disk yet
    /// or hasn't been compiled.
    case modelNotReady
    /// Backend-specific reason that doesn't fit the buckets above.
    /// Free-form string; surfaced to callers for logging / UI.
    case custom(String)
}
