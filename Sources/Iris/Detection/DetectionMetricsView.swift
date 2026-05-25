import SwiftUI

/// Structured, full-pane readout of a `DetectionMetrics` gauge — the verbose
/// counterpart to `DetectionMetrics.compactSummary` (the one-line HUD pill).
///
/// **Counts lead.** The instrument's ground truth is the raw frame split:
/// how many frames the source emitted, how many the pipeline processed, how
/// many it dropped. Those three numbers head the **Frames** row; the derived
/// drop *percentage* trails them, small and secondary — it's a reading off the
/// counts, not a primary number. Inference cost and throughput follow.
///
/// **Observation.** `DetectionMetrics` is `@MainActor @Observable`; reading its
/// properties inside `body` registers SwiftUI's dependency tracking, so the
/// rows re-render as samples land. The view is `@MainActor` to match.
///
/// Compact by construction — caption-weight, monospaced digits, secondary
/// styling — so it composes inside a tuning pane without dominating it.
@MainActor
public struct DetectionMetricsView: View {

    /// The gauge to read. Observed: `body` reads its properties directly.
    let metrics: DetectionMetrics

    public init(metrics: DetectionMetrics) {
        self.metrics = metrics
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(label: "Frames", value: framesValue, trailing: dropTrailing)
            row(label: "Inference", value: inferenceValue)
            row(label: "Throughput", value: throughputValue)
        }
        .font(.caption)
        .monospacedDigit()
    }

    // MARK: - Rows

    /// One label-value line: a fixed-width secondary label, the primary value,
    /// and an optional small/secondary trailing fragment (used for the derived
    /// drop %, which trails the raw counts rather than leading).
    @ViewBuilder
    private func row(label: String, value: String, trailing: String? = nil)
        -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
            if let trailing {
                Text(trailing)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Formatting

    /// `emitted E · processed P · dropped D` — raw counts lead. `—` until any
    /// frame has been seen (emitted or processed or dropped).
    private var framesValue: String {
        let emitted = metrics.emittedCount
        let processed = metrics.processedCount
        let dropped = metrics.droppedCount
        guard emitted + processed + dropped > 0 else { return "—" }
        return "emitted \(emitted) · processed \(processed) · dropped \(dropped)"
    }

    /// Derived drop-rate, small and secondary, trailing the raw counts. `nil`
    /// (no trailing fragment) until at least one frame opportunity exists.
    private var dropTrailing: String? {
        guard metrics.processedCount + metrics.droppedCount > 0 else { return nil }
        return "(\(Int((metrics.dropRate * 100).rounded()))%)"
    }

    /// `avg A ms · last L ms`. `—` until the first inference sample.
    private var inferenceValue: String {
        guard let avg = metrics.averageInferenceMillis else { return "—" }
        let avgStr = "avg \(Int(avg.rounded())) ms"
        if let last = metrics.lastInferenceMillis {
            return "\(avgStr) · last \(Int(last.rounded())) ms"
        }
        return avgStr
    }

    /// `R/s`. `—` until at least two samples (one interval) exist.
    private var throughputValue: String {
        guard let rate = metrics.effectiveDetectionsPerSecond else { return "—" }
        return String(format: "%.1f/s", rate)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("DetectionMetricsView · populated") {
    let metrics = DetectionMetrics()
    // Push a few synthetic samples so the rows render with real values: a
    // handful of inference timings (drives avg/last + throughput) plus
    // cumulative emit / drop counts bridged from a notional source.
    for ms in [22.0, 28.0, 25.0, 31.0, 27.0] {
        metrics.recordInference(seconds: ms / 1000)
    }
    metrics.setEmitted(312)
    metrics.setDropped(7)

    return DetectionMetricsView(metrics: metrics)
        .padding()
        .frame(width: 360)
}

#Preview("DetectionMetricsView · empty") {
    DetectionMetricsView(metrics: DetectionMetrics())
        .padding()
        .frame(width: 360)
}
#endif
