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
/// confidence floor — the **global** render floor every per-label floor clamps
/// to. It stays here. The per-class state (per-label floors + tri-state
/// show/hide) is **per-detector** and now lives on ``DetectorLabelStore``
/// (M12·P1), keyed by ``detectorID``. The combined library ``OverlayFilter`` the
/// demos thread into `DetectionLayer` across Playback / Image / Capture is
/// assembled by the store for the active detector.
///
/// **M12·P1 bridge.** The per-class accessors that used to live here
/// (`visibility(of:)`, `setVisibility`, `cycleVisibility`, `setPerLabelFloor`,
/// `overlayFilter`, and the `perLabelMinConfidence` / `hiddenLabels` /
/// `pinnedLabels` properties) are now thin forwarders onto ``labelStore`` keyed
/// by the active ``detectorID``, so the panel UI keeps compiling unchanged until
/// P3 re-points it at the store directly. The stored state moved off this object;
/// these are computed views over the store's active slice.
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

    /// The per-detector per-class store (M12·P1). Owns floors + tri-state
    /// visibility, keyed by detector id. The per-class accessors below forward
    /// to it using the active ``detectorID``.
    let labelStore: DetectorLabelStore

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

    // MARK: - Per-class bridge (M12·P1 — P3 re-points the panel)
    //
    // The three per-class collections, the tri-state helpers, and `overlayFilter`
    // moved onto `DetectorLabelStore`, keyed per-detector. These forwarders keep
    // the panel UI (`PerClassControls` / `PerClassRow`) and previews compiling
    // unchanged against `modelSelection.<x>` until P3 re-points them at the store
    // + the active detector id directly. Each computed view reads/writes the
    // store's slice for the *active* `detectorID`. Reading them in a view body
    // observes `labelStore.detectors`, so the rows still update live.

    /// Per-label confidence floors for the **active detector**, as a flat map
    /// (bridge view of the store's slice). Setting reconciles the whole map into
    /// the store (clamped to the global floor on the store side).
    // M12·P1 bridge — P3 re-points the panel.
    var perLabelMinConfidence: [String: Double] {
        get {
            var out: [String: Double] = [:]
            for label in labelStore.labels(for: detectorID) {
                if let floor = labelStore.floor(of: label, for: detectorID) {
                    out[label] = floor
                }
            }
            return out
        }
        set {
            let current = perLabelMinConfidence
            for label in current.keys where newValue[label] == nil {
                labelStore.clearPerLabelFloor(of: label, for: detectorID)
            }
            for (label, value) in newValue where current[label] != value {
                labelStore.setPerLabelFloor(value, of: label, for: detectorID, globalFloor: minConfidence)
            }
        }
    }

    /// Labels hidden outright for the **active detector** (bridge view of the
    /// store). Setting reconciles which labels are `.hide` into the store.
    // M12·P1 bridge — P3 re-points the panel.
    var hiddenLabels: Set<String> {
        get { labelSet(matching: .hide) }
        set { reconcileVisibility(newValue, target: .hide) }
    }

    /// Labels **pinned** ("Show") for the **active detector** (bridge view of the
    /// store). Setting reconciles which labels are `.show` into the store.
    // M12·P1 bridge — P3 re-points the panel.
    var pinnedLabels: Set<String> {
        get { labelSet(matching: .show) }
        set { reconcileVisibility(newValue, target: .show) }
    }

    /// The library render-time filter for the **active detector**, assembled by
    /// the store (clamped to the global `minConfidence`). Read by `DetectionLayer`
    /// across Playback / Image / Capture; observing the store's slice re-runs each
    /// overlay `body` when any knob moves.
    var overlayFilter: OverlayFilter {
        labelStore.overlayFilter(for: detectorID, globalFloor: minConfidence)
    }

    // MARK: - Per-class tri-state visibility (forwarders)

    /// The current tri-state for `label` under the active detector.
    func visibility(of label: String) -> LabelVisibility {
        labelStore.visibility(of: label, for: detectorID)
    }

    /// Set a label's tri-state under the active detector.
    func setVisibility(_ visibility: LabelVisibility, for label: String) {
        labelStore.setVisibility(visibility, of: label, for: detectorID)
    }

    /// Cycle a label Hide → Auto → Show → Hide under the active detector.
    func cycleVisibility(of label: String) {
        labelStore.cycleVisibility(of: label, for: detectorID)
    }

    /// Set a per-label confidence floor under the active detector, clamped to
    /// ≥ the global floor (the clamp lives in the store).
    func setPerLabelFloor(_ value: Double, for label: String) {
        labelStore.setPerLabelFloor(value, of: label, for: detectorID, globalFloor: minConfidence)
    }

    // MARK: - Bridge helpers

    /// Labels under the active detector whose stored visibility matches `target`.
    private func labelSet(matching target: DetectorLabelStore.Visibility) -> Set<String> {
        let triState: LabelVisibility = target == .hide ? .hide : .show
        return labelStore.labels(for: detectorID).filter {
            labelStore.visibility(of: $0, for: detectorID) == triState
        }
    }

    /// Reconcile the active detector's `target`-visibility labels to exactly
    /// `desired`: labels gaining `target` are set to it; labels losing it drop to
    /// Auto. (Bridge semantics for whole-set assignment / `removeAll()`.)
    private func reconcileVisibility(_ desired: Set<String>, target: DetectorLabelStore.Visibility) {
        let triState: LabelVisibility = target == .hide ? .hide : .show
        let current = labelSet(matching: target)
        for label in current.subtracting(desired) {
            labelStore.setVisibility(.auto, of: label, for: detectorID)
        }
        for label in desired.subtracting(current) {
            labelStore.setVisibility(triState, of: label, for: detectorID)
        }
    }

    private let defaults: UserDefaults

    /// - Parameters:
    ///   - defaults: `UserDefaults` instance to read/write. Override for tests.
    ///   - labelStore: the per-detector per-class store (M12·P1). Defaults to a
    ///     store on the same `defaults` so the demo wires one automatically;
    ///     tests / previews can inject a hermetic one.
    init(defaults: UserDefaults = .standard, labelStore: DetectorLabelStore? = nil) {
        self.defaults = defaults
        self.labelStore = labelStore ?? DetectorLabelStore(defaults: defaults)
        self.detectorID =
            defaults.string(forKey: Self.detectorIDKey) ?? Self.defaultDetectorID
        // `object(forKey:)` distinguishes "never set" (nil → default) from a
        // stored 0.0; `double(forKey:)` would silently coerce a missing key to 0.
        self.minConfidence =
            (defaults.object(forKey: Self.minConfidenceKey) as? Double)
            ?? Self.defaultMinConfidence
    }
}
