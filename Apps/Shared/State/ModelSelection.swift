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
/// **M12·P3 — the per-class bridge is gone.** The panel (`PerClassControls` /
/// `PerClassRow`) and the three detail views' overlay-filter assembly now talk
/// to ``labelStore`` + the active ``detectorID`` directly. The forwarders that
/// briefly lived here in P1 (`visibility(of:)`, `setVisibility`,
/// `cycleVisibility`, `setPerLabelFloor`, `overlayFilter`, and the
/// `perLabelMinConfidence` / `hiddenLabels` / `pinnedLabels` views) have been
/// removed — nothing reads per-class state through `ModelSelection` anymore. What
/// remains here is the selection (`detectorID`) the store is keyed *by* and the
/// global render floor (`minConfidence`) the store clamps to.
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
