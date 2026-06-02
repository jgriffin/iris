import Iris
import SwiftUI

/// The pinned-top `MODEL` section: the detector `Picker` (MRU-ordered, with
/// not-ready entries dimmed) plus the render-time min-confidence floor. Wraps
/// its content in the shared `SidebarSection("MODEL")` container.
struct ModelSection: View {
    let catalog: DetectorCatalog
    let recentDetectors: RecentDetectors
    let modelStore: DemoModelStore
    @Bindable var modelSelection: ModelSelection

    /// Labels currently visible in the active mode — drives the present-only
    /// per-class rows (M10·P3). Empty for class-agnostic detectors / before any
    /// detection, in which case `PerClassControls` shows only a faint hint.
    let presentLabels: Set<String>

    var body: some View {
        SidebarSection("MODEL") {
            Picker("Detector", selection: $modelSelection.detectorID) {
                ForEach(recentDetectors.sortedEntries(catalog)) { entry in
                    detectorRow(for: entry).tag(entry.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("Active detector")

            // Render-time min-confidence floor — a draw-time OVERLAY filter
            // (what gets drawn), distinct from the per-detector Tune sheet
            // (what the detector emits). One slider drives the shared
            // `ModelSelection`, so every page's overlay honors it. Relocated
            // here from the interim toolbar / control-bar placements (M9·P3).
            MinConfidenceControl(modelSelection: modelSelection)
                // Indented to read as a setting nested under the detector picker.
                .padding(.leading, 16)

            // The per-class Display/filter group (M10·P3): per-label visibility
            // + confidence floor over the present-only roster. Visually
            // delineated from the global floor by a divider; gated to nothing
            // extra (a faint hint) when no labels are present.
            Divider()
            PerClassControls(
                modelSelection: modelSelection,
                presentLabels: presentLabels
            )
            .padding(.leading, 16)
        }
    }

    @ViewBuilder
    private func detectorRow(for entry: DetectorCatalogEntry) -> some View {
        if modelStore.availability(forEntryID: entry.id) == .modelNotReady {
            Text(entry.displayName).foregroundStyle(.secondary)
        } else {
            Text(entry.displayName)
        }
    }
}

/// The render-time min-confidence labeled slider. A small private subview so the
/// `MODEL` section's body reads cleanly.
private struct MinConfidenceControl: View {
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

#if DEBUG
#Preview {
    let store = PreviewFixtures.modelStore
    ModelSection(
        catalog: PreviewFixtures.catalog(store: store),
        recentDetectors: PreviewFixtures.recentDetectors,
        modelStore: store,
        modelSelection: PreviewFixtures.modelSelection,
        presentLabels: ["person", "sports ball", "car", "dog"]
    )
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .frame(width: 280)
}
#endif
