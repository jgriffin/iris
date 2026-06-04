import Foundation
import Iris
import Observation

/// The single, app-level model selection shared across every mode of the Iris
/// demos (M9·P2). Replaces the four independent per-page detector selections
/// (iOS Playback + Image, macOS Videos + Images) with ONE selection lifted to
/// the app root and injected via `.environment`. Every page reads the SAME
/// `detectorID`, so switching the model in one mode is reflected in all of them
/// — Playback and Image now always run the same detector, and the Image page no
/// longer silently flips its detector on re-appear.
///
/// **Render-time overlay filter (M9·P3 + M10).** `minConfidence` is the global
/// confidence floor; `perLabelMinConfidence` overrides it per `Detection.label`,
/// and `hiddenLabels` drops labels outright. The three combine into
/// ``overlayFilter``, the library ``OverlayFilter`` the demos thread into
/// `DetectionLayer` across Playback / Image / Capture. All three persist so a
/// tuning setup survives relaunch.
///
/// Persistence mirrors `RecentDetectors`: a `UserDefaults`-backed `@Observable`
/// that loads in `init` and writes on every set via `didSet`. The `.v1` key
/// suffixes let a future schema bump migrate without trashing the stored value.
///
/// Concurrency: `@Observable` + `@MainActor`. All mutations happen from the UI
/// thread; `UserDefaults` is the single backing store and this is its single
/// writer.
@MainActor
@Observable
final class ModelSelection {
    /// Storage keys. `.v1` lets future schema bumps migrate cleanly.
    static let detectorIDKey = "iris.model.selectedDetectorID.v1"
    static let minConfidenceKey = "iris.model.minConfidence.v1"
    static let perLabelMinConfidenceKey = "iris.model.perLabelMinConfidence.v1"
    static let hiddenLabelsKey = "iris.model.hiddenLabels.v1"
    static let pinnedLabelsKey = "iris.model.pinnedLabels.v1"

    /// Default launch detector — preserved from the prior per-page defaults so
    /// behavior is unchanged until the user picks something else.
    static let defaultDetectorID = "vision.rectangles"

    /// Default minimum confidence. Held + persisted only; consumed in P3.
    static let defaultMinConfidence = 0.25

    /// The app-wide selected detector id (a `DetectorCatalogEntry.id`). Every
    /// mode binds its picker to this and resolves it through the catalog.
    /// Persisted on set.
    var detectorID: String {
        didSet { defaults.set(detectorID, forKey: Self.detectorIDKey) }
    }

    /// App-wide global minimum-confidence floor — the fallback for any label
    /// without a `perLabelMinConfidence` entry. Consumed via ``overlayFilter``.
    /// Persisted on set.
    var minConfidence: Double {
        didSet { defaults.set(minConfidence, forKey: Self.minConfidenceKey) }
    }

    /// Per-label confidence floors keyed on `Detection.label`, overriding the
    /// global `minConfidence` for those labels (M10). Persisted on set.
    var perLabelMinConfidence: [String: Double] {
        didSet { defaults.set(perLabelMinConfidence, forKey: Self.perLabelMinConfidenceKey) }
    }

    /// Labels hidden outright — dropped from the overlay regardless of
    /// confidence (M10). Persisted on set as an array (`UserDefaults` has no
    /// native `Set`), re-hydrated to a `Set` in `init`.
    ///
    /// **Tri-state.** A label is in at most one of {`hiddenLabels`,
    /// `pinnedLabels`}; in neither it is *Auto* (drawn when present, default for
    /// a newly-seen label). `setVisibility` enforces the mutual exclusion.
    var hiddenLabels: Set<String> {
        didSet { defaults.set(Array(hiddenLabels), forKey: Self.hiddenLabelsKey) }
    }

    /// Labels **pinned** ("Show") — always LISTED in the per-class UI (and drawn
    /// when present, even before they first appear). Pinning is purely app-side
    /// UI/listing state: drawing-wise Show == Auto (both draw when present), so
    /// `OverlayFilter` needs no "pinned" field — only `hiddenLabels` affects
    /// what's drawn. Persisted like `hiddenLabels`. Mutually exclusive with it.
    var pinnedLabels: Set<String> {
        didSet { defaults.set(Array(pinnedLabels), forKey: Self.pinnedLabelsKey) }
    }

    /// The library render-time filter assembled from the app-side knobs
    /// (`Double` → `Float`). Read by `DetectionLayer` across Playback / Image /
    /// Capture; observing it re-runs each overlay `body` when any knob moves.
    ///
    /// **Pinned doesn't enter the filter** — Show == Auto for drawing, so only
    /// `hiddenLabels` suppresses. **Per-label floors are clamped to ≥ the global
    /// floor** here too (belt-and-suspenders with the UI clamp), so a stale
    /// stored override below a raised global floor can never *loosen* below it.
    var overlayFilter: OverlayFilter {
        OverlayFilter(
            globalMinConfidence: Float(minConfidence),
            perLabelMinConfidence: perLabelMinConfidence.mapValues {
                Float(max($0, minConfidence))
            },
            hiddenLabels: hiddenLabels
        )
    }

    // MARK: - Per-class tri-state visibility

    /// The drawing/listing state of a single class label.
    ///
    /// - ``hide``: never drawn, even when detected (`hiddenLabels`).
    /// - ``auto``: drawn when present; the DEFAULT for a newly-seen label
    ///   (in neither `hiddenLabels` nor `pinnedLabels`).
    /// - ``show``: pinned — always listed in the per-class UI + drawn when
    ///   present, even before it first appears (`pinnedLabels`).
    enum LabelVisibility: Sendable, CaseIterable {
        case hide, auto, show
    }

    /// The current tri-state for `label`. Hidden takes precedence over pinned
    /// (the two sets are kept mutually exclusive, so this is just a lookup).
    func visibility(of label: String) -> LabelVisibility {
        if hiddenLabels.contains(label) { return .hide }
        if pinnedLabels.contains(label) { return .show }
        return .auto
    }

    /// Set a label's tri-state, enforcing the {hidden, pinned} mutual exclusion.
    func setVisibility(_ visibility: LabelVisibility, for label: String) {
        switch visibility {
        case .hide:
            pinnedLabels.remove(label)
            hiddenLabels.insert(label)
        case .auto:
            hiddenLabels.remove(label)
            pinnedLabels.remove(label)
        case .show:
            hiddenLabels.remove(label)
            pinnedLabels.insert(label)
        }
    }

    /// Cycle a label Hide → Auto → Show → Hide (the eye-tap affordance order).
    func cycleVisibility(of label: String) {
        switch visibility(of: label) {
        case .hide: setVisibility(.auto, for: label)
        case .auto: setVisibility(.show, for: label)
        case .show: setVisibility(.hide, for: label)
        }
    }

    /// Set a per-label confidence floor, clamped to ≥ the global floor. A
    /// per-class floor can be stricter than the global one, never looser — the
    /// global `minConfidence` is a hard render-side floor everything sits above.
    func setPerLabelFloor(_ value: Double, for label: String) {
        perLabelMinConfidence[label] = max(value, minConfidence)
    }

    private let defaults: UserDefaults

    /// - Parameter defaults: `UserDefaults` instance to read/write. Override for
    ///   tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.detectorID =
            defaults.string(forKey: Self.detectorIDKey) ?? Self.defaultDetectorID
        // `object(forKey:)` distinguishes "never set" (nil → default) from a
        // stored 0.0; `double(forKey:)` would silently coerce a missing key to 0.
        self.minConfidence =
            (defaults.object(forKey: Self.minConfidenceKey) as? Double)
            ?? Self.defaultMinConfidence
        self.perLabelMinConfidence =
            (defaults.dictionary(forKey: Self.perLabelMinConfidenceKey) as? [String: Double])
            ?? [:]
        self.hiddenLabels =
            Set((defaults.array(forKey: Self.hiddenLabelsKey) as? [String]) ?? [])
        self.pinnedLabels =
            Set((defaults.array(forKey: Self.pinnedLabelsKey) as? [String]) ?? [])
    }
}
