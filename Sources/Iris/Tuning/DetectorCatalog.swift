import SwiftUI

// MARK: - ActiveDetectorSession

/// A type-erased, ready-to-run detector + its capability-derived tuning UI.
/// Built by a `DetectorCatalogEntry`'s factory (which captures the concrete
/// `TunableDetector` type), so the player can hold "the active detector and
/// its settings panel" without knowing the type at compile time. The
/// `router` is the seam `DetectorPipeline` already consumes; `settingsView`
/// is a `CapabilityTuningView` erased to `AnyView`.
@MainActor
public struct ActiveDetectorSession {
    public let router: any TuningRouter
    public let settingsView: AnyView
    public init(router: any TuningRouter, settingsView: AnyView) {
        self.router = router
        self.settingsView = settingsView
    }
}

// MARK: - DetectorCatalogEntry

/// One selectable detector in the catalog: a stable id, a display name, and
/// a factory that builds a fresh `ActiveDetectorSession` bound to the given
/// detection cache.
@MainActor
public struct DetectorCatalogEntry: Identifiable {
    public let id: String
    public let displayName: String
    public let makeSession: @MainActor (any DetectionCache) -> ActiveDetectorSession
    public init(
        id: String,
        displayName: String,
        makeSession: @escaping @MainActor (any DetectionCache) -> ActiveDetectorSession
    ) {
        self.id = id
        self.displayName = displayName
        self.makeSession = makeSession
    }
}

extension DetectorCatalogEntry {
    /// Build an entry whose factory constructs `TuningModel(detector:cache:)`
    /// and a `CapabilityTuningView` for it, erased into an `ActiveDetectorSession`.
    ///
    /// This is the one-liner seam: both the built-in Vision entries and any
    /// app-supplied entry (e.g. a Core ML model) declare themselves by
    /// passing a fresh-detector factory and a display name — no per-detector
    /// UI authoring, because `CapabilityTuningView` derives its controls from
    /// the detector's `DetectorCapabilities`.
    public static func make<D: TunableDetector>(
        id: String,
        displayName: String,
        detector: @escaping @MainActor () -> D
    ) -> DetectorCatalogEntry {
        DetectorCatalogEntry(id: id, displayName: displayName) { cache in
            let tuning = TuningModel(detector: detector(), cache: cache)
            return ActiveDetectorSession(
                router: tuning,
                settingsView: AnyView(CapabilityTuningView(model: tuning))
            )
        }
    }
}

// MARK: - DetectorCatalog

/// The list of available detectors a player can choose among. Ships with the
/// built-in Vision detectors; apps append their own (e.g. Core ML models).
@MainActor
public struct DetectorCatalog {
    public var entries: [DetectorCatalogEntry]
    public init(entries: [DetectorCatalogEntry]) { self.entries = entries }
}

extension DetectorCatalog {
    /// The two built-in Vision detectors: rectangles (no probabilistic
    /// confidence) and body pose (per-element joint confidence). Rectangles
    /// is first so a player defaulting to the head of the list preserves the
    /// pre-M5 behavior; the user picks Body Pose to see the skeleton overlay.
    public static var builtInVision: DetectorCatalog {
        DetectorCatalog(entries: [
            .make(id: "vision.rectangles", displayName: "Rectangles") {
                VisionRectanglesDetector(
                    minimumAspectRatio: 0.3,
                    maximumAspectRatio: 1.0,
                    minimumSize: 0.1,
                    label: "rect"
                )
            },
            .make(id: "vision.bodyPose", displayName: "Body Pose") {
                VisionBodyPoseDetector()
            },
        ])
    }
}
