import CoreML
import Iris
import OSLog
import SwiftUI

/// Demo-app detector catalog: the built-in Vision detectors plus the two
/// converted Core ML YOLO detectors — **YOLOv12n** (path A, M6·P2) and
/// **YOLO26n** (path B, M6·P3).
///
/// **Why this lives in the demo, not the Iris package.** Locating a model
/// bundled into the app target is a *consumer* concern — the Iris package
/// can't reach into `Bundle.main` for an app's resources, and
/// `DetectorCatalog.builtInVision` stays Vision-only by design. The demo
/// composes its own catalog by appending app-specific entries (here, the Core
/// ML models the demo target bundles) to the built-in list. This is exactly
/// the extension seam M6 calls for: "Core ML models register as entries
/// exactly like the built-in Vision ones."
///
/// **Two catalog paths, one per decoder shape.** The YOLOv12n entry is a
/// plain `Detector` (path-A thresholds are baked at export), so it registers
/// through the **non-tunable** `DetectorCatalogEntry.make(id:displayName:detector:)`
/// overload and carries an empty settings view. The YOLO26n entry's detector
/// **is** a `TunableDetector` (path B exposes a runtime confidence knob via
/// `YOLOEnd2EndDecoder: TunableOutputDecoder`), so it registers through the
/// `make<D: TunableDetector>(...)` overload — which builds a real
/// `TuningModel` + `CapabilityTuningView` + router automatically. This
/// exercises both catalog paths side by side.
///
/// If a model resource is missing from the bundle (e.g. a build that didn't
/// add it to Resources) or fails to compile, that entry is simply omitted with
/// a logged warning — the picker still works with whatever loaded.
enum DemoCatalog {

    private static let logger = Logger(subsystem: "iris.demo", category: "catalog")

    /// Stable id for the YOLOv12n (path A) catalog entry; also the
    /// `selectedDetectorID` to pick it.
    static let yolo12nEntryID = "coreml.yolo12n"

    /// Stable id for the YOLO26n (path B) catalog entry.
    static let yolo26nEntryID = "coreml.yolo26n"

    /// The catalog the demo's playback picker reads: built-in Vision detectors
    /// followed by the Core ML YOLO entries (each appended only when its model
    /// resource is present in the app bundle).
    @MainActor
    static var detectors: DetectorCatalog {
        var entries = DetectorCatalog.builtInVision.entries
        if let yolo12n = makeYOLO12nEntry() {
            entries.append(yolo12n)
        }
        if let yolo26n = makeYOLO26nEntry() {
            entries.append(yolo26n)
        }
        return DetectorCatalog(entries: entries)
    }

    /// Locate a bundled model by base name. The demo target bundles each
    /// `.mlpackage`, which **Xcode compiles to `<name>.mlmodelc` at build
    /// time**, so the runtime resource is the compiled `.mlmodelc` — that's the
    /// primary lookup. The `.mlpackage` fallback covers a build that copied the
    /// source package unchanged (and is the form the package's fixture test
    /// uses). Returns the URL plus whether it still needs compiling.
    private static func bundledModelURL(named name: String) -> (url: URL, compiled: Bool)? {
        if let compiled = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            return (compiled, true)
        }
        if let source = Bundle.main.url(forResource: name, withExtension: "mlpackage") {
            return (source, false)
        }
        return nil
    }

    /// Load a bundled model synchronously (compiling the `.mlpackage` if Xcode
    /// didn't pre-compile it). Returns `nil` on any failure, logging the cause.
    @MainActor
    private static func loadBundledModel(named name: String) -> MLModel? {
        guard let bundled = bundledModelURL(named: name) else {
            logger.error("\(name) model vanished between catalog build and session build")
            return nil
        }
        do {
            return bundled.compiled
                ? try CoreMLModelLoading.loadCompiled(at: bundled.url)
                : try CoreMLModelLoading.compileAndLoadSync(at: bundled.url)
        } catch {
            logger.error("Failed to load \(name) Core ML model: \(String(describing: error))")
            return nil
        }
    }

    /// Build the YOLOv12n (path-A) entry via the **non-tunable** catalog
    /// overload. Returns `nil` (with a warning) if the resource is absent, so
    /// the catalog degrades gracefully.
    @MainActor
    private static func makeYOLO12nEntry() -> DetectorCatalogEntry? {
        guard bundledModelURL(named: "yolo12n") != nil else {
            logger.warning(
                "yolo12n model not found in Bundle.main — add yolo12n.mlpackage to the demo target Resources to surface the Core ML detector"
            )
            return nil
        }

        return DetectorCatalogEntry.make(
            id: yolo12nEntryID,
            displayName: "YOLOv12n (Core ML)"
        ) { () -> any Detector in
            // The factory is synchronous; load inline. A failure here can't
            // propagate out of the non-throwing factory, so fall back to a
            // no-op detector and log — the catalog entry stays selectable but
            // produces no detections, preferable to crashing the picker.
            guard let model = loadBundledModel(named: "yolo12n") else {
                return EmptyDetector(modelIdentifier: yolo12nEntryID)
            }
            do {
                return try CoreMLDetector(
                    model: model,
                    decoder: VisionObjectDecoder(),
                    modelIdentifier: yolo12nEntryID
                )
            } catch {
                logger.error("Failed to build YOLOv12n detector: \(String(describing: error))")
                return EmptyDetector(modelIdentifier: yolo12nEntryID)
            }
        }
    }

    /// Build the YOLO26n (path-B) entry via the **tunable** catalog overload —
    /// its `CoreMLDetector<YOLOEnd2EndDecoder>` conforms to `TunableDetector`,
    /// so this path gives it a real confidence-threshold settings view +
    /// router automatically. The factory returns the concrete tunable type
    /// (not erased to `any Detector`) so `make<D: TunableDetector>` binds.
    ///
    /// **Why the model loads in the entry builder, not the factory.** The
    /// tunable overload's factory must return a `CoreMLDetector<…>` — a *valid*
    /// one (it wraps a compiled `MLModel` container, which can't be faked into
    /// an "unavailable" stand-in without a model). So we load the model **once,
    /// up front**: if it can't load, the entry is omitted entirely (the picker
    /// degrades gracefully); if it loads, the factory captures the `MLModel`
    /// and only constructs the detector — which can still `throw`, but from a
    /// pre-loaded, valid model that essentially never fails. A failure there
    /// is logged and the entry is dropped at build time, never mid-factory.
    @MainActor
    private static func makeYOLO26nEntry() -> DetectorCatalogEntry? {
        guard let model = loadBundledModel(named: "yolo26n") else {
            logger.warning(
                "yolo26n model unavailable — add yolo26n.mlpackage to the demo target Resources to surface the path-B Core ML detector"
            )
            return nil
        }

        // Validate the detector builds before registering the entry, so the
        // factory closure (which can't surface a throw) is guaranteed to
        // succeed by re-running the same construction on the captured model.
        guard
            (try? CoreMLDetector(
                model: model,
                decoder: YOLOEnd2EndDecoder(labels: COCOLabels.coco80),
                modelIdentifier: yolo26nEntryID
            )) != nil
        else {
            logger.error("YOLO26n detector failed to build — omitting catalog entry")
            return nil
        }

        return DetectorCatalogEntry.make(
            id: yolo26nEntryID,
            displayName: "YOLO26n (Core ML)"
        ) { () -> CoreMLDetector<YOLOEnd2EndDecoder> in
            // Safe to force-try: the identical construction succeeded a moment
            // ago against this same pre-loaded model in the guard above.
            try! CoreMLDetector(
                model: model,
                decoder: YOLOEnd2EndDecoder(labels: COCOLabels.coco80),
                modelIdentifier: yolo26nEntryID
            )
        }
    }
}

/// A `Detector` that never detects anything — the graceful fallback when the
/// Core ML model fails to load inside the synchronous catalog factory (which
/// can't throw out). Keeps the picker functional; the user sees no boxes and
/// the logged error explains why.
private struct EmptyDetector: Detector {
    let availability: DetectorAvailability = .modelNotReady
    let modelIdentifier: String
    func prewarm() async {}
    func detect(in _: Frame) async throws -> [Detection] { [] }
}
