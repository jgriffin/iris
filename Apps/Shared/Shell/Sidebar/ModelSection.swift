import Iris
import SwiftUI

/// The pinned-top `MODEL` section: just the detector `Picker` (MRU-ordered,
/// with not-ready entries dimmed). Wraps its content in the shared
/// `SidebarSection("MODEL")` container.
///
/// **Min-confidence moved out (redesign).** The render-time global
/// min-confidence floor used to live here as a nested slider; it now lives in
/// the inspector's `Tuning` → **Display** group, atop the per-class rows (see
/// `MinConfidenceControl`). The MODEL section is now purely the picker.
struct ModelSection: View {
    let catalog: DetectorCatalog
    let recentDetectors: RecentDetectors
    let modelStore: DemoModelStore
    @Bindable var modelSelection: ModelSelection

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

#if DEBUG
#Preview {
    let store = PreviewFixtures.modelStore
    ModelSection(
        catalog: PreviewFixtures.catalog(store: store),
        recentDetectors: PreviewFixtures.recentDetectors,
        modelStore: store,
        modelSelection: PreviewFixtures.modelSelection
    )
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .frame(width: 280)
}
#endif
