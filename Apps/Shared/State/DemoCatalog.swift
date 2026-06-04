import CoreML
import Iris
import Observation
import OSLog
import SwiftUI

/// Demo-app detector catalog + model store: the built-in Vision detectors,
/// the two **bundled** converted Core ML YOLO detectors — **YOLOv12n** (path A,
/// M6·P2) and **YOLO26n** (path B, M6·P3) — and a **file-picked** Path-A slot
/// the user fills with their own `.mlpackage`/`.mlmodel` (M6·P3 model-swap).
///
/// **Why this lives in the demo, not the Iris package.** Locating a model
/// bundled into the app target, presenting a file picker, and caching loaded
/// `MLModel`s are all *consumer* concerns — the Iris package can't reach into
/// `Bundle.main` for an app's resources, and per the M4 doctrine UI +
/// file-picking live in the demo. Iris provides the loading primitive
/// (`CoreMLModelLoading`), the detector (`CoreMLDetector`), and the
/// availability semantics (`DetectorAvailability`); the demo composes them.
///
/// **Three catalog paths.**
/// - **YOLOv12n** (bundled, path A) — a plain `Detector` (path-A thresholds
///   are baked at export), registered through the **non-tunable**
///   `DetectorCatalogEntry.make(id:displayName:detector:)` overload.
/// - **YOLO26n** (bundled, path B) — a `TunableDetector` (path B exposes a
///   runtime confidence knob via `YOLOEnd2EndDecoder: TunableOutputDecoder`),
///   registered through `make<D: TunableDetector>(...)`, which builds a real
///   `TuningModel` + `CapabilityTuningView` automatically.
/// - **Custom Core ML model (Path A)** (file-picked) — starts as a
///   `.modelNotReady` placeholder; once the user picks a Path-A
///   (`nms=True` / NMS-pipeline) `.mlpackage`/`.mlmodel`, it becomes a real
///   `CoreMLDetector<VisionObjectDecoder>` whose labels self-describe (zero
///   config). Path-B file-picking is a noted follow-on, intentionally not
///   built — a raw-tensor model needs externally-supplied labels + a decoder
///   choice the picker can't infer.
///
/// **Prewarm + caching (`DemoModelStore`).** The bundled models are loaded +
/// `prewarm()`ed in a background task at launch so the first selection isn't a
/// cold stall (Core ML's first-inference cost is real). The store caches the
/// warmed detector so `makeSession` reuses the warmed instance rather than
/// recompiling. The store is `@MainActor @Observable` so the playback picker
/// re-renders when the file-picked slot transitions `.modelNotReady` →
/// `.available`.

// MARK: - DemoModelStore

/// Holds demo-app Core ML model state across catalog recomputes: warmed
/// bundled detectors and the file-picked detector (if loaded). `@Observable`
/// so the picker re-renders when the file-picked slot flips to loaded.
@MainActor
@Observable
final class DemoModelStore {

    private static let logger = Logger(subsystem: "iris.demo", category: "models")

    /// The file-picked detector once a model is loaded; `nil` while the slot
    /// is still the `.modelNotReady` placeholder. A plain `Detector` (Path A,
    /// `VisionObjectDecoder` — non-tunable), built from the picked file.
    private(set) var pickedDetector: CoreMLDetector<VisionObjectDecoder>?

    /// Display label for the loaded file-picked model (the file basename), or
    /// `nil` while unloaded. Surfaced in the picker so the row shows which
    /// model is active.
    private(set) var pickedModelName: String?

    /// Last file-pick error, surfaced by the demo's `errorText` pattern when a
    /// picked model fails to load (invalid / incompatible). Cleared on the next
    /// successful pick.
    private(set) var pickedModelError: String?

    /// Warmed bundled detectors, keyed by base name (`yolo12n`, `yolo26n`),
    /// populated by `prewarmBundledModels()`. `makeSession` reuses these so a
    /// selection doesn't recompile the model. A `nil` value (vs. absent key)
    /// records a bundled model that's simply not in this build's Resources, so
    /// the catalog omits its entry without re-probing the bundle.
    private var warmedBundled: [String: (any Detector)?] = [:]

    init() {}

    // MARK: Bundled prewarm-at-launch

    /// Load + `prewarm()` the bundled YOLO models off the main actor so the
    /// first selection isn't a cold stall. Best-effort: a model that isn't in
    /// this build's Resources is recorded as absent (its catalog entry is
    /// omitted); a load failure is logged and skipped. Idempotent — the demo
    /// kicks this off once from `.task` at launch.
    ///
    /// Each loaded detector is `prewarm()`ed (one throwaway inference) so Core
    /// ML compiles its compute path before the user's first frame.
    func prewarmBundledModels() async {
        await prewarmBundled(named: "yolo12n", decoder: VisionObjectDecoder())
        await prewarmBundled(named: "yolo26n", decoder: YOLOEnd2EndDecoder(labels: COCOLabels.coco80))
    }

    private func prewarmBundled<D: OutputDecoder>(named name: String, decoder: D) async {
        // Already attempted (warmed, or recorded-absent) — don't redo.
        if warmedBundled[name] != nil { return }

        guard let (url, compiled) = Self.bundledModelURL(named: name) else {
            Self.logger.warning(
                "\(name) not in Bundle.main — add \(name).mlpackage to the demo target Resources to surface its Core ML detector"
            )
            // Record the miss so the catalog omits the entry without re-probing.
            warmedBundled[name] = .some(nil)
            return
        }

        do {
            let model = compiled
                ? try CoreMLModelLoading.loadCompiled(at: url)
                : try await CoreMLModelLoading.compileAndLoad(at: url)
            let detector = try CoreMLDetector(
                model: model,
                decoder: decoder,
                modelIdentifier: "coreml.\(name)"
            )
            await detector.prewarm()
            warmedBundled[name] = .some(detector)
            Self.logger.info("Prewarmed bundled model \(name)")
        } catch {
            Self.logger.error("Failed to load/prewarm \(name): \(String(describing: error))")
            warmedBundled[name] = .some(nil)
        }
    }

    /// The warmed bundled detector for `name`, or `nil` if not (yet) warmed or
    /// absent from this build. `makeSession` factories read this so a selection
    /// reuses the warmed instance.
    func warmedDetector(named name: String) -> (any Detector)? {
        if case let .some(detector) = warmedBundled[name] { return detector }
        return nil
    }

    /// Whether a bundled model is present in this build (warmed or pending),
    /// used to decide whether to surface its catalog entry. Before
    /// `prewarmBundledModels()` runs we don't yet know, so fall back to a cheap
    /// bundle probe.
    func bundledModelIsPresent(named name: String) -> Bool {
        switch warmedBundled[name] {
        case .some(.some): return true   // warmed
        case .some(.none): return false  // recorded absent
        case nil: return Self.bundledModelURL(named: name) != nil  // not yet probed
        }
    }

    // MARK: File-picked load

    /// Load a user-picked Path-A model from `url`, build a
    /// `CoreMLDetector<VisionObjectDecoder>`, prewarm it, and store it as the
    /// file-picked detector. On failure, records `pickedModelError` and leaves
    /// the slot `.modelNotReady`. The basename becomes the model identifier +
    /// the picker's display label.
    ///
    /// Path A only: `VisionObjectDecoder` reads labels off the model's NMS
    /// pipeline, so the picked model self-describes — zero config. A picked
    /// Path-B (raw-tensor) model would load but decode to nothing through this
    /// decoder; the demo accepts only Path A by design (noted follow-on).
    func loadPickedModel(at url: URL) async {
        let name = url.deletingPathExtension().lastPathComponent
        do {
            let model = try await CoreMLModelLoading.compileAndLoad(at: url)
            let detector = try CoreMLDetector(
                model: model,
                decoder: VisionObjectDecoder(),
                modelIdentifier: name
            )
            await detector.prewarm()
            pickedDetector = detector
            pickedModelName = name
            pickedModelError = nil
            Self.logger.info("Loaded + prewarmed file-picked model \(name)")
        } catch {
            let message = "Could not load \(url.lastPathComponent): \(error.localizedDescription)"
            Self.logger.error(
                "Failed to load file-picked model \(name): \(String(describing: error))"
            )
            pickedDetector = nil
            pickedModelName = nil
            pickedModelError = message
        }
    }

    // MARK: Availability (read by the picker UI)

    /// Availability for a catalog entry id, as the picker should display it.
    /// This is the first UI consumer of `DetectorAvailability`: the file-picked
    /// `coreml.custom` slot is `.modelNotReady` until a model is loaded, then
    /// `.available`; everything else (built-in Vision, bundled YOLO) is
    /// `.available`. Bundled-model entries only appear in the catalog when
    /// present, so they're always `.available` by the time they're shown.
    func availability(forEntryID id: String) -> DetectorAvailability {
        if id == DemoCatalog.customEntryID {
            return pickedDetector == nil ? .modelNotReady : .available
        }
        return .available
    }

    // MARK: Bundle lookup

    /// Locate a bundled model by base name. The demo target bundles each
    /// `.mlpackage`, which **Xcode compiles to `<name>.mlmodelc` at build
    /// time**, so the runtime resource is the compiled `.mlmodelc` — that's the
    /// primary lookup. The `.mlpackage` fallback covers a build that copied the
    /// source package unchanged. Returns the URL plus whether it's compiled.
    static func bundledModelURL(named name: String) -> (url: URL, compiled: Bool)? {
        if let compiled = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            return (compiled, true)
        }
        if let source = Bundle.main.url(forResource: name, withExtension: "mlpackage") {
            return (source, false)
        }
        return nil
    }
}

// MARK: - DemoCatalog

enum DemoCatalog {

    private static let logger = Logger(subsystem: "iris.demo", category: "catalog")

    /// Stable id for the YOLOv12n (path A) catalog entry.
    static let yolo12nEntryID = "coreml.yolo12n"

    /// Stable id for the YOLO26n (path B) catalog entry.
    static let yolo26nEntryID = "coreml.yolo26n"

    /// Stable id for the file-picked Path-A custom-model entry. Always present
    /// in the catalog (as a placeholder until a model is loaded), so the user
    /// can select it to trigger the importer.
    static let customEntryID = "coreml.custom"

    /// Build the catalog the demo's playback picker reads, given the model
    /// store: built-in Vision detectors, the bundled Core ML YOLO entries
    /// (each only when its model is present in this build), and the file-picked
    /// custom-model entry (placeholder until loaded).
    @MainActor
    static func detectors(store: DemoModelStore) -> DetectorCatalog {
        var entries = DetectorCatalog.builtInVision.entries
        if store.bundledModelIsPresent(named: "yolo12n") {
            entries.append(makeYOLO12nEntry(store: store))
        } else {
            logger.warning(
                "yolo12n model not found in Bundle.main — its catalog entry is omitted"
            )
        }
        if store.bundledModelIsPresent(named: "yolo26n") {
            if let yolo26n = makeYOLO26nEntry(store: store) {
                entries.append(yolo26n)
            }
        } else {
            logger.warning(
                "yolo26n model not found in Bundle.main — its catalog entry is omitted"
            )
        }
        entries.append(makeCustomEntry(store: store))
        return DetectorCatalog(entries: entries)
    }

    // MARK: Bundled entries

    /// The YOLOv12n (path-A) entry via the **non-tunable** catalog overload.
    /// The factory reuses the warmed bundled detector from the store when
    /// available, so a selection doesn't recompile; if warm-up hasn't finished
    /// (or didn't run), it falls back to a fresh synchronous load.
    @MainActor
    private static func makeYOLO12nEntry(store: DemoModelStore) -> DetectorCatalogEntry {
        DetectorCatalogEntry.make(
            id: yolo12nEntryID,
            displayName: "YOLOv12n (Core ML)"
        ) { () -> any Detector in
            if let warmed = store.warmedDetector(named: "yolo12n") {
                return warmed
            }
            // Warm-up not finished — load inline (sub-second for this small
            // package). The factory can't throw out, so fall back to a
            // never-detects placeholder on failure (logged).
            guard let model = loadBundledModelSync(named: "yolo12n") else {
                return NotReadyDetector(modelIdentifier: yolo12nEntryID)
            }
            do {
                return try CoreMLDetector(
                    model: model,
                    decoder: VisionObjectDecoder(),
                    modelIdentifier: yolo12nEntryID
                )
            } catch {
                logger.error("Failed to build YOLOv12n detector: \(String(describing: error))")
                return NotReadyDetector(modelIdentifier: yolo12nEntryID)
            }
        }
    }

    /// The YOLO26n (path-B) entry via the **tunable** catalog overload. Its
    /// `CoreMLDetector<YOLOEnd2EndDecoder>` conforms to `TunableDetector`, so
    /// this gives it a confidence-threshold settings view automatically. The
    /// factory must return the concrete tunable type, so it can't reuse the
    /// `any Detector`-typed warmed instance — it rebuilds from the warmed (or
    /// freshly loaded) `MLModel` container, which is the cheap part.
    @MainActor
    private static func makeYOLO26nEntry(store: DemoModelStore) -> DetectorCatalogEntry? {
        // Prefer the warmed model; fall back to a sync load.
        let warmedModel: MLModel?
        if let warmed = store.warmedDetector(named: "yolo26n") as? CoreMLDetector<YOLOEnd2EndDecoder> {
            // Rebuild around the warmed container by reloading is unnecessary —
            // capture the warmed detector directly via its identifier reuse.
            // The tunable overload needs the concrete type, which we have.
            return DetectorCatalogEntry.make(
                id: yolo26nEntryID,
                displayName: "YOLO26n (Core ML)",
                availableLabels: COCOLabels.coco80,
                hidesConfidenceControl: true
            ) { () -> CoreMLDetector<YOLOEnd2EndDecoder> in warmed }
        } else {
            warmedModel = loadBundledModelSync(named: "yolo26n")
        }

        guard let model = warmedModel else {
            logger.error("YOLO26n model unavailable — omitting catalog entry")
            return nil
        }
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
            displayName: "YOLO26n (Core ML)",
            availableLabels: COCOLabels.coco80,
            hidesConfidenceControl: true
        ) { () -> CoreMLDetector<YOLOEnd2EndDecoder> in
            try! CoreMLDetector(
                model: model,
                decoder: YOLOEnd2EndDecoder(labels: COCOLabels.coco80),
                modelIdentifier: yolo26nEntryID
            )
        }
    }

    // MARK: File-picked entry

    /// The file-picked Path-A custom-model entry. When no model is loaded yet,
    /// its factory yields a `.modelNotReady` placeholder so the picker can grey
    /// / annotate it; once `store.pickedDetector` is set, the factory yields
    /// the loaded `CoreMLDetector<VisionObjectDecoder>` (a plain `Detector`,
    /// non-tunable — Path A's thresholds are baked) via the non-tunable
    /// overload.
    @MainActor
    private static func makeCustomEntry(store: DemoModelStore) -> DetectorCatalogEntry {
        DetectorCatalogEntry.make(
            id: customEntryID,
            displayName: customDisplayName(store: store)
        ) { () -> any Detector in
            if let picked = store.pickedDetector {
                return picked
            }
            return NotReadyDetector(modelIdentifier: customEntryID)
        }
    }

    /// Display name for the custom entry: a stable base plus a status suffix so
    /// the picker reflects load state inline ("— not loaded" until a model is
    /// supplied, the model name once it is).
    @MainActor
    static func customDisplayName(store: DemoModelStore) -> String {
        if let name = store.pickedModelName {
            return "Custom Core ML model — \(name)"
        }
        return "Custom Core ML model (Path A) — not loaded"
    }

    // MARK: Sync bundled load (fallback)

    @MainActor
    private static func loadBundledModelSync(named name: String) -> MLModel? {
        guard let (url, compiled) = DemoModelStore.bundledModelURL(named: name) else {
            return nil
        }
        do {
            return compiled
                ? try CoreMLModelLoading.loadCompiled(at: url)
                : try CoreMLModelLoading.compileAndLoadSync(at: url)
        } catch {
            logger.error("Failed to load \(name) Core ML model: \(String(describing: error))")
            return nil
        }
    }
}

/// A `Detector` that never detects anything and reports `.modelNotReady` — the
/// placeholder for an unloaded file-pick slot and the graceful fallback when a
/// bundled model fails to load inside the synchronous catalog factory (which
/// can't throw out). Keeps the picker functional; the user sees no boxes, the
/// `.modelNotReady` availability greys the picker row, and any logged error
/// explains why.
struct NotReadyDetector: Detector {
    let availability: DetectorAvailability = .modelNotReady
    let modelIdentifier: String
    func prewarm() async {}
    func detect(in _: Frame) async throws -> [Detection] { [] }
}
