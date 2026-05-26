import Iris
import OSLog
import SwiftUI

/// Demo-app detector catalog: the built-in Vision detectors plus the
/// converted Core ML YOLOv12n detector (M6·P2).
///
/// **Why this lives in the demo, not the Iris package.** Locating a model
/// bundled into the app target is a *consumer* concern — the Iris package
/// can't reach into `Bundle.main` for an app's resources, and
/// `DetectorCatalog.builtInVision` stays Vision-only by design. The demo
/// composes its own catalog by appending app-specific entries (here, a Core
/// ML model the demo target bundles) to the built-in list. This is exactly
/// the extension seam M6 calls for: "Core ML models register as entries
/// exactly like the built-in Vision ones."
///
/// The YOLOv12n entry is registered through the non-tunable
/// `DetectorCatalogEntry.make(id:displayName:detector:)` overload (P2's
/// `CoreMLDetector` conforms to `Detector` only — path-A thresholds are baked
/// at export), so it carries an empty settings view in the tuning sheet.
///
/// If the model resource is missing from the bundle (e.g. a build that didn't
/// add it to Resources) or fails to compile, the entry is simply omitted with
/// a logged warning — the picker still works with the Vision detectors.
enum DemoCatalog {

    private static let logger = Logger(subsystem: "iris.demo", category: "catalog")

    /// Stable id for the YOLOv12n catalog entry; also the `selectedDetectorID`
    /// to pick it.
    static let yoloEntryID = "coreml.yolo12n"

    /// The catalog the demo's playback picker reads: built-in Vision detectors
    /// followed by the Core ML YOLOv12n entry (when its model resource is
    /// present in the app bundle).
    @MainActor
    static var detectors: DetectorCatalog {
        var entries = DetectorCatalog.builtInVision.entries
        if let yolo = makeYOLOEntry() {
            entries.append(yolo)
        }
        return DetectorCatalog(entries: entries)
    }

    /// Locate the bundled YOLOv12n model. The demo target bundles the
    /// `.mlpackage`, which **Xcode compiles to `yolo12n.mlmodelc` at build
    /// time**, so the runtime resource is the compiled `.mlmodelc` — that's the
    /// primary lookup. The `.mlpackage` fallback covers a build that copied the
    /// source package unchanged (and is the form the package's fixture test
    /// uses). Returns the URL plus whether it still needs compiling.
    private static func bundledModelURL() -> (url: URL, compiled: Bool)? {
        if let compiled = Bundle.main.url(forResource: "yolo12n", withExtension: "mlmodelc") {
            return (compiled, true)
        }
        if let source = Bundle.main.url(forResource: "yolo12n", withExtension: "mlpackage") {
            return (source, false)
        }
        return nil
    }

    /// Build the YOLOv12n entry, locating the bundled model and loading it at
    /// session-build time. Returns `nil` (with a warning) if the resource is
    /// absent, so the catalog degrades gracefully to Vision-only.
    @MainActor
    private static func makeYOLOEntry() -> DetectorCatalogEntry? {
        guard bundledModelURL() != nil else {
            logger.warning(
                "yolo12n model not found in Bundle.main — add yolo12n.mlpackage to the demo target Resources to surface the Core ML detector"
            )
            return nil
        }

        return DetectorCatalogEntry.make(
            id: yoloEntryID,
            displayName: "YOLOv12n (Core ML)"
        ) { () -> any Detector in
            // The factory is synchronous; load inline. A failure here can't
            // propagate out of the non-throwing factory, so fall back to a
            // no-op detector and log — the catalog entry stays selectable but
            // produces no detections, preferable to crashing the picker.
            guard let bundled = bundledModelURL() else {
                logger.error("yolo12n model vanished between catalog build and session build")
                return EmptyDetector(modelIdentifier: yoloEntryID)
            }
            do {
                let model =
                    bundled.compiled
                    ? try CoreMLModelLoading.loadCompiled(at: bundled.url)
                    : try CoreMLModelLoading.compileAndLoadSync(at: bundled.url)
                return try CoreMLDetector(
                    model: model,
                    decoder: VisionObjectDecoder(),
                    modelIdentifier: yoloEntryID
                )
            } catch {
                logger.error("Failed to load YOLOv12n Core ML model: \(String(describing: error))")
                return EmptyDetector(modelIdentifier: yoloEntryID)
            }
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
