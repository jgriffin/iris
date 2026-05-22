/// Runs multiple `Detector`s over a single `Frame` and flattens their
/// results.
///
/// Detectors are executed in parallel via `withThrowingTaskGroup`; per-task
/// results are then re-assembled in the same order the detectors were
/// supplied so the output ordering is deterministic and stable across
/// runs. This matters because downstream rendering and dataset code keys
/// off `[Detection]` ordering when there are no other tiebreakers (e.g.,
/// equal confidences, equal labels) — non-determinism here would surface
/// as flicker in overlays and noise in sidecar diffs.
///
/// **Failure mode.** If any detector throws, the pipeline cancels the
/// others and rethrows the first error to surface. Partial results are
/// not returned. Callers that want best-effort behavior should wrap their
/// inner detectors in a forgiving adapter.
///
/// **Concurrency.** `Sendable` via `[any Detector]` (which is `Sendable`
/// because `Detector: Sendable`). The pipeline itself is a stateless
/// `struct` so it crosses actor boundaries freely.
public struct DetectorPipeline: Detector {

    private let detectors: [any Detector]

    public let availability: DetectorAvailability = .available

    public let modelIdentifier: String = "pipeline"

    /// Build a pipeline that fans out across the supplied detectors in
    /// parallel and concatenates their results in input order.
    public init(_ detectors: [any Detector]) {
        self.detectors = detectors
    }

    /// Variadic convenience: `DetectorPipeline(rectDetector, faceDetector)`.
    public init(_ detectors: any Detector...) {
        self.detectors = detectors
    }

    /// Prewarms every wrapped detector in parallel. Returns once all have
    /// completed.
    public func prewarm() async {
        await withTaskGroup(of: Void.self) { group in
            for detector in detectors {
                group.addTask { await detector.prewarm() }
            }
        }
    }

    /// Runs every wrapped detector against `frame` in parallel. The
    /// resulting `[Detection]` is the concatenation of each detector's
    /// output in the order the detectors were supplied to `init` — not
    /// the order tasks happened to complete.
    public func detect(in frame: Frame) async throws -> [Detection] {
        try await withThrowingTaskGroup(
            of: (offset: Int, detections: [Detection]).self
        ) { group in
            for (offset, detector) in detectors.enumerated() {
                group.addTask {
                    let dets = try await detector.detect(in: frame)
                    return (offset, dets)
                }
            }

            var slots: [[Detection]] = Array(repeating: [], count: detectors.count)
            for try await result in group {
                slots[result.offset] = result.detections
            }
            return slots.flatMap { $0 }
        }
    }
}
