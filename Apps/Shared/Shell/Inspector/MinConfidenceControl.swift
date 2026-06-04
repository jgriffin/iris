import Iris
import SwiftUI

/// The render-time **global min-confidence** labeled slider — a draw-time
/// OVERLAY filter (what gets *drawn*), distinct from the per-detector input
/// knobs (what the detector *emits*). One slider drives the shared
/// `ModelSelection.minConfidence`, so every page's overlay honors it.
///
/// Relocated from the sidebar MODEL section into the inspector's `Tuning`
/// section's **Display** group (the redesign): it now sits at the top of the
/// per-class group, above the per-class rows, as the global floor the per-class
/// overrides fall back to. Kept as a small reusable view so its single home is
/// unambiguous. The label stays exactly "Min confidence" — NOT "all classes":
/// it's a render-side floor (M9 decision), and the Raw inspector stays honest.
struct MinConfidenceControl: View {
    @Bindable var modelSelection: ModelSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Min confidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f", modelSelection.minConfidence))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $modelSelection.minConfidence, in: 0...1, step: 0.05)
                .accessibilityLabel("Minimum confidence")
        }
    }
}
