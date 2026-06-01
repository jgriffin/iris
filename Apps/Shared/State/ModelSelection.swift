import Foundation
import Observation

/// The single, app-level model selection shared across every mode of the Iris
/// demos (M9·P2). Replaces the four independent per-page detector selections
/// (iOS Playback + Image, macOS Videos + Images) with ONE selection lifted to
/// the app root and injected via `.environment`. Every page reads the SAME
/// `detectorID`, so switching the model in one mode is reflected in all of them
/// — Playback and Image now always run the same detector, and the Image page no
/// longer silently flips its detector on re-appear.
///
/// **`minConfidence` is held and persisted but NOT yet consumed.** It is wired
/// to the overlay / pipeline in P3 — for now it is a parked knob that survives
/// relaunch so P3 has a stored value to read. Do not consume it anywhere yet.
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

    /// App-wide minimum confidence. **Held and persisted but not yet consumed**
    /// — wired to the overlay / pipeline in P3. Persisted on set.
    var minConfidence: Double {
        didSet { defaults.set(minConfidence, forKey: Self.minConfidenceKey) }
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
    }
}
