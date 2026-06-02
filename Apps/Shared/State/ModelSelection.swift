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
    var hiddenLabels: Set<String> {
        didSet { defaults.set(Array(hiddenLabels), forKey: Self.hiddenLabelsKey) }
    }

    /// The library render-time filter assembled from the three app-side knobs
    /// (`Double` → `Float`). Read by `DetectionLayer` across Playback / Image /
    /// Capture; observing it re-runs each overlay `body` when any knob moves.
    var overlayFilter: OverlayFilter {
        OverlayFilter(
            globalMinConfidence: Float(minConfidence),
            perLabelMinConfidence: perLabelMinConfidence.mapValues(Float.init),
            hiddenLabels: hiddenLabels
        )
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
    }
}
