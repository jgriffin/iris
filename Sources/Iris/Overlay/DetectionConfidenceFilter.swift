/// Render-time **overlay filter** for detections (M9·P3, generalized M10·P1).
///
/// There are two distinct settings roles in Iris. *Detector settings* change
/// what a detector emits (the per-detector Tune sheet). This is the other one:
/// a render-time filter that takes whatever the detector already emitted and
/// decides what to *draw*, without changing the underlying detections. The
/// overlay (`DetectionLayer`) applies it at draw time; the raw-data inspector
/// (`DetectionInspector`) deliberately does not, so the raw view stays honest.
///
/// M9·P3 shipped a single GLOBAL minimum-confidence floor. M10·P1 generalizes
/// it into ``OverlayFilter`` — per-label floors + a hidden-label set, with the
/// global floor as the fallback — while keeping the scalar `filtered(minConfidence:)`
/// form working as a thin wrapper. The filter logic lives in exactly one place
/// (``filtered(by:)``); the scalar form delegates to it.

/// A render-time filter describing what to *draw* from a detector's emitted
/// `[Detection]`. Pure, value-typed, `Codable` so app-side state can persist it.
///
/// **Precedence** (per the M10 design, see `plans/features/per-class-tuning.md`):
/// 1. A label in ``hiddenLabels`` is dropped outright — *hidden wins*, even
///    above its floor.
/// 2. Otherwise the floor for a detection is its ``perLabelMinConfidence``
///    entry if present, else ``globalMinConfidence`` (the global fallback).
/// 3. The detection is kept iff its `confidence` is at or above that floor
///    (inclusive `>=`).
///
/// The empty/zero filter (no hidden labels, no per-label entries, a
/// non-positive global floor) is a behavior-neutral passthrough — see
/// ``Swift/Array/filtered(by:)``.
public struct OverlayFilter: Sendable, Hashable, Codable {

    /// The global minimum-confidence floor — the M9·P3 scalar, now the
    /// fallback applied to any label without a ``perLabelMinConfidence`` entry.
    /// A floor of `0` (the default) keeps everything at the global level.
    public var globalMinConfidence: Float

    /// Per-label overrides of the global floor, keyed on `Detection.label`. A
    /// label present here uses its own floor instead of ``globalMinConfidence``
    /// — in either direction (a stricter or a looser floor than the global).
    public var perLabelMinConfidence: [String: Float]

    /// Labels hidden outright. A detection whose `label` is in this set is
    /// always dropped, regardless of its confidence or any floor — *hidden
    /// wins*.
    public var hiddenLabels: Set<String>

    public init(
        globalMinConfidence: Float = 0,
        perLabelMinConfidence: [String: Float] = [:],
        hiddenLabels: Set<String> = []
    ) {
        self.globalMinConfidence = globalMinConfidence
        self.perLabelMinConfidence = perLabelMinConfidence
        self.hiddenLabels = hiddenLabels
    }

    /// `true` when the filter has nothing to do: no hidden labels, no per-label
    /// overrides, and a non-positive global floor. The fast-path guard in
    /// ``Swift/Array/filtered(by:)`` returns the input unchanged in this case.
    var isNoOp: Bool {
        hiddenLabels.isEmpty
            && perLabelMinConfidence.isEmpty
            && globalMinConfidence <= 0
    }
}

extension Array where Element == Detection {

    /// Detections kept by `filter`, applying hidden-label and per-label /
    /// global confidence-floor precedence.
    ///
    /// Pure and order-preserving — the single source of truth for the
    /// render-time filter logic. Fast-path: when `filter` is a no-op (see
    /// ``OverlayFilter/isNoOp``) the receiver is returned by identity with no
    /// allocation, mirroring the original scalar guard.
    public func filtered(by filter: OverlayFilter) -> [Detection] {
        guard !filter.isNoOp else { return self }
        return self.filter { detection in
            // 1. Hidden wins outright.
            guard !filter.hiddenLabels.contains(detection.label) else {
                return false
            }
            // 2. Per-label floor if set, otherwise the global floor.
            let floor = filter.perLabelMinConfidence[detection.label]
                ?? filter.globalMinConfidence
            // 3. Inclusive `>=` boundary — a detection exactly at the floor is
            //    kept. (A floor of `0` keeps everything; detectors that stamp a
            //    constant `1.0`, e.g. Vision rectangles, survive any sub-1.0
            //    floor, while real-score detectors feel it.)
            return detection.confidence >= floor
        }
    }

    /// Detections whose `confidence` is at or above `minConfidence` — the M9·P3
    /// scalar form, preserved verbatim in behavior.
    ///
    /// Thin wrapper over ``filtered(by:)`` so the floor semantics live in one
    /// place: equivalent to `filtered(by: OverlayFilter(globalMinConfidence: minConfidence))`.
    /// A floor of `0` keeps everything; the boundary is inclusive (`>=`).
    public func filtered(minConfidence: Float) -> [Detection] {
        filtered(by: OverlayFilter(globalMinConfidence: minConfidence))
    }
}
