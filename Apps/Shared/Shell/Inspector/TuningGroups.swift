import Iris
import SwiftUI

/// The redesigned inspector tuning panel (mock Variant 3). No section chrome:
/// the "Tuning" title, the "DETECTOR" caption, and the "DISPLAY" caption are all
/// dropped. The panel reads top-to-bottom as:
///
/// 1. The active detector's **displayName** in a prominent bold callout.
/// 2. The suppressed-confidence `settingsView` (the detector's remaining input
///    knobs — often empty for YOLO, which renders nothing, by design).
/// 3. The single global **"Min confidence"** floor (`MinConfidenceControl`,
///    backed by the one `ModelSelection.minConfidence`).
/// 4. The dense **per-class** list (a "PER CLASS" caption + trailing "Reset all",
///    then one value-only row per class — see `PerClassControls`).
///
/// There is exactly ONE "Min confidence" control: the detector's own confidence
/// knob is suppressed in the catalog (`hidesConfidenceControl: true` →
/// `CapabilityTuningView(hidesConfidence:)`), so the only confidence control on
/// screen is the global floor here.
struct TuningGroups: View {
    /// The active detector's display name (e.g. "YOLO26n (Core ML)"), or `nil`
    /// when no detector is resolved.
    let detectorName: String?

    /// The detector's capability-derived knob view (confidence already
    /// suppressed by the catalog), or `nil` when there's no active session.
    let settingsView: AnyView?

    @Bindable var modelSelection: ModelSelection
    let presentLabels: Set<String>
    let availableLabels: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Prominent detector-name callout — the panel's header (no "DETECTOR"
            // caption above it). Larger + bold per the mock's `.detector-name`.
            if let detectorName {
                Text(detectorName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The detector's remaining input knobs (confidence suppressed). Often
            // empty for YOLO → renders nothing, which is fine.
            if let settingsView {
                settingsView
            }

            // The single global render-side floor — the fallback the per-class
            // overrides clamp to. Label stays exactly "Min confidence".
            MinConfidenceControl(modelSelection: modelSelection)

            PerClassControls(
                modelSelection: modelSelection,
                presentLabels: presentLabels,
                availableLabels: availableLabels
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
