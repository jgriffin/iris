/// Render-time **overlay filter** for detection confidence (M9·P3).
///
/// There are two distinct settings roles in Iris. *Detector settings* change
/// what a detector emits (the per-detector Tune sheet). This is the other one:
/// a render-time filter that takes whatever the detector already emitted and
/// decides what to *draw*, without changing the underlying detections. The
/// overlay (`DetectionLayer`) applies it at draw time; the raw-data inspector
/// (`DetectionInspector`) deliberately does not, so the raw view stays honest.
///
/// The filter is a single GLOBAL minimum-confidence floor keyed on
/// `Detection.confidence`. It is intentionally NOT per-class — per-class
/// filtering is a deferred backlog generalization.
extension Array where Element == Detection {

    /// Detections whose `confidence` is at or above `minConfidence`.
    ///
    /// Pure and order-preserving. A floor of `0` keeps everything (the
    /// behavior-neutral default). Boundary is inclusive (`>=`): a detection
    /// exactly at the floor is kept. Detectors that don't emit real scores
    /// stamp `confidence == 1.0` (e.g. Vision rectangles), so they survive any
    /// floor `< 1.0`; detectors that emit real scores (e.g. YOLO) feel it.
    public func filtered(minConfidence: Float) -> [Detection] {
        // `minConfidence <= 0` is the overwhelmingly common no-op case — skip
        // the allocation and return self by identity.
        guard minConfidence > 0 else { return self }
        return filter { $0.confidence >= minConfidence }
    }
}
