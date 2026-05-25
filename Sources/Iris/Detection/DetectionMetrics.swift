import Foundation

// MARK: - DetectionMetrics

/// Best-effort pipeline gauge.
///
/// Iris runs detection on a best-effort basis (see `plans/DECISIONS.md`
/// §"Runtime frame pipeline" — the pipeline sheds frames under load rather
/// than blocking the source). That decision makes *how hard the pipeline is
/// straining* invisible by construction: frames silently drop, inference
/// time drifts, and nothing surfaces it. `DetectionMetrics` is the
/// instrument that makes the strain legible — it measures, it does not
/// control. Nothing in this type changes pipeline behavior; it only
/// records what the pipeline already did so a UI can show it.
///
/// What it surfaces:
/// - **Inference cost** — `lastInferenceMillis` and a rolling-window
///   `averageInferenceMillis` (last `windowSize` samples).
/// - **Drop pressure** — `processedCount` vs. `droppedCount` and the derived
///   `dropRate` (0...1). Drops are sourced from the source's cumulative
///   counter via `setDropped(_:)`.
/// - **Throughput** — `effectiveDetectionsPerSecond`, processed events over
///   a rolling wall-clock window.
///
/// `@MainActor @Observable` — matches the project's `@Observable` idiom so
/// SwiftUI views observing it re-render as samples land. All state is
/// main-actor-isolated; callers driving a detection loop off the main actor
/// must hop (`await MainActor.run { … }`) to record.
///
/// Allocation-light: two fixed-cap ring-style arrays (durations + processed
/// timestamps), trimmed to `windowSize`. No per-frame heap churn beyond the
/// bounded append/remove.
@MainActor
@Observable
public final class DetectionMetrics {

    /// Rolling-window size for both the inference-time average and the
    /// throughput wall-clock window.
    private static let windowSize = 30

    /// Most recent inference duration, in milliseconds. `nil` until the
    /// first `recordInference(seconds:)`.
    public private(set) var lastInferenceMillis: Double?

    /// Total frames the pipeline processed (one per `recordInference`).
    public private(set) var processedCount: Int = 0

    /// Cumulative dropped-frame total, mirrored from the source's counter
    /// via `setDropped(_:)`.
    public private(set) var droppedCount: Int = 0

    /// Cumulative emitted-frame total, mirrored from the source's counter
    /// (`PlaybackSource.emittedFrameCount`) via `setEmitted(_:)`. This is
    /// every frame the source handed downstream — the denominator the raw
    /// `processedCount` / `droppedCount` split is read against.
    public private(set) var emittedCount: Int = 0

    /// Rolling window of the last `windowSize` inference durations (seconds).
    private var recentDurations: [Double] = []

    /// Wall-clock instants of the last `windowSize` processed events, for the
    /// effective-throughput computation.
    private var recentProcessedAt: [ContinuousClock.Instant] = []

    private let clock = ContinuousClock()

    public init() {}

    // MARK: - Derived gauges

    /// Mean of the rolling inference-duration window, in milliseconds. `nil`
    /// until at least one sample exists.
    public var averageInferenceMillis: Double? {
        guard !recentDurations.isEmpty else { return nil }
        let meanSeconds = recentDurations.reduce(0, +) / Double(recentDurations.count)
        return meanSeconds * 1000
    }

    /// Fraction of frame opportunities that were dropped rather than
    /// processed, in `0...1`. `droppedCount / max(1, dropped + processed)`.
    public var dropRate: Double {
        Double(droppedCount) / Double(max(1, droppedCount + processedCount))
    }

    /// Processed events over the rolling wall-clock window, in events per
    /// second. `nil` until at least two samples exist (one interval). Uses
    /// the span from the oldest to the newest tracked timestamp.
    public var effectiveDetectionsPerSecond: Double? {
        guard recentProcessedAt.count >= 2,
            let first = recentProcessedAt.first,
            let last = recentProcessedAt.last
        else { return nil }
        let elapsed = first.duration(to: last)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        guard seconds > 0 else { return nil }
        // Count of intervals, not samples: N timestamps span (N-1) gaps.
        return Double(recentProcessedAt.count - 1) / seconds
    }

    // MARK: - Recording

    /// Record one completed inference of `seconds` duration. Appends to the
    /// rolling duration window, updates `lastInferenceMillis`, increments
    /// `processedCount`, and marks a processed wall-clock timestamp for the
    /// throughput window. The single per-frame call site.
    public func recordInference(seconds: Double) {
        lastInferenceMillis = seconds * 1000

        recentDurations.append(seconds)
        if recentDurations.count > Self.windowSize {
            recentDurations.removeFirst(recentDurations.count - Self.windowSize)
        }

        recordProcessed()
    }

    /// Increment the processed count and mark a throughput timestamp.
    /// Folded into `recordInference(seconds:)`; exposed for call sites that
    /// count a processed frame without a timing sample.
    public func recordProcessed() {
        processedCount += 1
        recentProcessedAt.append(clock.now)
        if recentProcessedAt.count > Self.windowSize {
            recentProcessedAt.removeFirst(recentProcessedAt.count - Self.windowSize)
        }
    }

    /// Set `droppedCount` to an absolute cumulative total. The source
    /// exposes a per-session cumulative drop counter
    /// (`PlaybackSource.droppedFrameCount`); the demo bridges it in here
    /// rather than tracking drops independently.
    public func setDropped(_ total: Int) {
        droppedCount = total
    }

    /// Set `emittedCount` to an absolute cumulative total. Mirrors
    /// `setDropped(_:)` — the source exposes a per-session cumulative emit
    /// counter (`PlaybackSource.emittedFrameCount`); the demo bridges it in
    /// here rather than tracking emits independently.
    public func setEmitted(_ total: Int) {
        emittedCount = total
    }

    /// Zero every counter and clear the rolling windows. Called on
    /// video / detector swap so counts are per-session.
    public func reset() {
        lastInferenceMillis = nil
        processedCount = 0
        droppedCount = 0
        emittedCount = 0
        recentDurations.removeAll(keepingCapacity: true)
        recentProcessedAt.removeAll(keepingCapacity: true)
    }

    // MARK: - Display

    /// Compact, single-line readout for a status bar / HUD pill, leading with
    /// the raw counts, e.g. `312 done · 0 drop · 28 ms` (processed · dropped ·
    /// avg-ms). Counts lead because they're the ground truth — the derived
    /// drop % moves to the full `DetectionMetricsView`. The avg-ms field falls
    /// back to a `—` placeholder until the first inference sample lands. Lives
    /// here so both demos format identically (single source of truth).
    public var compactSummary: String {
        let done = "\(processedCount) done"
        let drop = "\(droppedCount) drop"

        let ms: String
        if let avg = averageInferenceMillis {
            ms = "\(Int(avg.rounded())) ms"
        } else {
            ms = "— ms"
        }

        return "\(done) · \(drop) · \(ms)"
    }
}
