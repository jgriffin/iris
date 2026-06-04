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

    /// The detector's full class roster, when statically known (e.g. the COCO-80
    /// set for a stock YOLO box detector), else `nil`. Surfaced WITHOUT building
    /// a session so a per-class UI can offer "show all classes" before the
    /// detector ever runs. `nil` means *no static roster* (a dynamic / class-
    /// agnostic detector like Vision rectangles) — the consumer falls back to
    /// the seen-only labels. This mirrors
    /// ``DetectorCapabilities/availableLabels`` but is reachable at the catalog
    /// level so the shell needn't instantiate (and warm) a detector to read it.
    public let availableLabels: [String]?

    public init(
        id: String,
        displayName: String,
        availableLabels: [String]? = nil,
        makeSession: @escaping @MainActor (any DetectionCache) -> ActiveDetectorSession
    ) {
        self.id = id
        self.displayName = displayName
        self.availableLabels = availableLabels
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
        availableLabels: [String]? = nil,
        hidesConfidenceControl: Bool = false,
        detector: @escaping @MainActor () -> D
    ) -> DetectorCatalogEntry {
        DetectorCatalogEntry(
            id: id,
            displayName: displayName,
            availableLabels: availableLabels
        ) { cache in
            let tuning = TuningModel(detector: detector(), cache: cache)
            return ActiveDetectorSession(
                router: tuning,
                settingsView: AnyView(
                    CapabilityTuningView(
                        model: tuning,
                        hidesConfidence: hidesConfidenceControl
                    )
                )
            )
        }
    }

    /// Build an entry for a **plain `Detector`** that has no runtime-tunable
    /// knobs (M6·P2's path-A `CoreMLDetector`, where thresholds are baked at
    /// export time).
    ///
    /// **Why a second overload, not the `TunableDetector` one.** The
    /// `make<D: TunableDetector>` seam routes everything through a
    /// `TuningModel`, which requires a `Settings` type and a per-knob
    /// classifier. A non-tunable detector has neither, and forcing a fake
    /// empty `TunableDetector` conformance would be a lie about the detector's
    /// capabilities. This overload wires a minimal ``PassthroughRouter``
    /// instead: it carries the detector for the pipeline to run, exposes no
    /// output transform, and pairs with an empty settings view. The detector
    /// still surfaces honest `DetectorCapabilities` for the inspector — it
    /// just has no tuning UI.
    public static func make(
        id: String,
        displayName: String,
        availableLabels: [String]? = nil,
        detector: @escaping @MainActor () -> any Detector
    ) -> DetectorCatalogEntry {
        DetectorCatalogEntry(
            id: id,
            displayName: displayName,
            availableLabels: availableLabels
        ) { _ in
            ActiveDetectorSession(
                router: PassthroughRouter(detector: detector()),
                settingsView: AnyView(EmptyView())
            )
        }
    }
}

// MARK: - PassthroughRouter

/// Minimal `TuningRouter` for a non-tunable `Detector`.
///
/// `DetectorPipeline` consults a `TuningRouter` only for two things: the
/// `currentDetector` to run (used in place of the pipeline's own array) and an
/// optional output `transform`. A detector with no runtime knobs needs neither
/// hot-swap nor a filter pass, so this router just holds the detector and
/// returns `nil`/no-op for the rest. It lets a plain `Detector` register as a
/// catalog entry without a `TuningModel` (which would require a `Settings`
/// type the detector doesn't have).
///
/// **Concurrency.** `@MainActor final class` matching `TuningModel`'s shape —
/// the only other `TuningRouter` conformer — so the pipeline reads it via the
/// same `MainActor.run` hop.
@MainActor
public final class PassthroughRouter: TuningRouter {

    private let detector: any Detector

    /// The detector the pipeline should run. Never `nil` for a passthrough
    /// router — that's its whole job.
    public var currentDetector: (any Detector)? { detector }

    /// No output transform: a non-tunable detector has no filter-tier knobs,
    /// so the pipeline returns its detections unchanged.
    public var transform: (@Sendable ([Detection]) -> [Detection])? { nil }

    /// Never fires — there are no detector-tier knob changes to react to.
    /// `var` to satisfy the protocol's settable requirement; setting it is a
    /// no-op in effect because nothing ever invokes it.
    public var onDetectorTierChange: (@Sendable @MainActor () -> Void)?

    public init(detector: any Detector) {
        self.detector = detector
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
            .make(
                id: "vision.rectangles",
                displayName: "Rectangles",
                hidesConfidenceControl: true
            ) {
                VisionRectanglesDetector(
                    minimumAspectRatio: 0.3,
                    maximumAspectRatio: 1.0,
                    minimumSize: 0.1,
                    label: "rect"
                )
            },
            .make(
                id: "vision.bodyPose",
                displayName: "Body Pose",
                hidesConfidenceControl: true
            ) {
                VisionBodyPoseDetector()
            },
        ])
    }
}
