import Iris
import SwiftUI

/// The per-class Display/filter group inside the MODEL section (M10·P3). For
/// each label currently visible in the active mode (the present-only roster
/// passed down from `IrisShell.presentLabels`), it renders one `PerClassRow`:
/// a visibility toggle + a per-label confidence floor that falls back to the
/// global floor until overridden.
///
/// **Present-only, render-side.** This surfaces only labels actually in the
/// detections right now — no full-roster expander (deferred: needs the
/// detector's `availableLabels` plumbed into the shell) and no detector-input
/// knobs (deferred: the `CapabilityTuningView` integration). Class-agnostic
/// detectors (Vision rectangles stamp `""`) contribute no labels, so the group
/// renders only a faint hint line. Per-class state lives app-side on
/// `ModelSelection` (`perLabelMinConfidence` + `hiddenLabels`), exactly like the
/// global floor — observing it re-runs each consuming overlay.
struct PerClassControls: View {
    @Bindable var modelSelection: ModelSelection

    /// Distinct, non-empty labels currently visible in the active mode. Sorted
    /// for a stable row order so rows don't reshuffle as the set changes.
    let presentLabels: Set<String>

    private var sortedLabels: [String] { presentLabels.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A quiet sub-label delineating the per-class group from the global
            // floor above it — same all-caps `.caption2` treatment the sidebar
            // uses for secondary captions, dialed one step quieter than the
            // section header so it reads as a subgroup, not a peer section.
            Text("PER CLASS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)

            if sortedLabels.isEmpty {
                Text("No classes detected yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(sortedLabels, id: \.self) { label in
                    PerClassRow(modelSelection: modelSelection, label: label)
                }
            }
        }
    }
}

/// One per-class row: an eye visibility toggle, the label, an override/reset
/// affordance, and a compact confidence-floor slider (M10·P3).
///
/// **Floor binding.** The slider drives a derived binding: `get` returns the
/// label's `perLabelMinConfidence` override if present, else the global
/// `minConfidence`; `set` writes the override. Touching the slider therefore
/// *creates* an override (and the • indicator + reset control appear); the
/// reset control removes the entry so the label follows the global floor again.
///
/// **Hidden precedence.** A hidden label (in `modelSelection.hiddenLabels`)
/// dims the row and disables the floor slider — its confidence is moot while
/// it's not drawn (matching the library filter's "hidden wins outright").
struct PerClassRow: View {
    @Bindable var modelSelection: ModelSelection
    let label: String

    private var isHidden: Bool { modelSelection.hiddenLabels.contains(label) }
    private var hasOverride: Bool { modelSelection.perLabelMinConfidence[label] != nil }

    /// Per-label floor, falling back to the global floor when unset. Writing
    /// installs an override for this label.
    private var floor: Binding<Double> {
        Binding(
            get: { modelSelection.perLabelMinConfidence[label] ?? modelSelection.minConfidence },
            set: { modelSelection.perLabelMinConfidence[label] = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    if isHidden {
                        modelSelection.hiddenLabels.remove(label)
                    } else {
                        modelSelection.hiddenLabels.insert(label)
                    }
                } label: {
                    Image(systemName: isHidden ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundStyle(isHidden ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isHidden ? "Show \(label)" : "Hide \(label)")

                Text(label)
                    .font(.caption)
                    .foregroundStyle(isHidden ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // The override dot — a subtle accent mark that the label's floor
                // diverges from the global one.
                if hasOverride {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 4)

                Text(String(format: "%.2f", floor.wrappedValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                // Reset-to-global — only when an override exists. Removing the
                // entry drops the label back to the global floor.
                if hasOverride {
                    Button {
                        modelSelection.perLabelMinConfidence[label] = nil
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Use global floor")
                    .accessibilityLabel("Reset \(label) to global floor")
                }
            }

            Slider(value: floor, in: 0...1, step: 0.05)
                .controlSize(.mini)
                .tint(hasOverride ? nil : Color.secondary)
                .disabled(isHidden)
                .opacity(isHidden ? 0.4 : 1)
                .accessibilityLabel("\(label) minimum confidence")
        }
    }
}

#if DEBUG
/// A deterministic `ModelSelection` for previews — its own throwaway suite so
/// each case starts from a known per-class state without touching real defaults.
@MainActor
private func previewSelection(
    global: Double = 0.30,
    overrides: [String: Double] = [:],
    hidden: Set<String> = []
) -> ModelSelection {
    let suite = "iris.preview.perclass.\(UUID().uuidString)"
    let sel = ModelSelection(defaults: UserDefaults(suiteName: suite)!)
    sel.minConfidence = global
    sel.perLabelMinConfidence = overrides
    sel.hiddenLabels = hidden
    return sel
}

private let previewLabels: Set<String> = ["person", "sports ball", "car", "dog"]

/// The favorite-pattern gallery: per-class controls in isolation with a mix of
/// hidden / overridden / global-following rows, light + dark. Renders the same
/// component the MODEL section embeds, at the sidebar's 280-pt width.
#Preview("Per-class · mixed · light") {
    PerClassControls(
        modelSelection: previewSelection(
            global: 0.30,
            overrides: ["sports ball": 0.65, "car": 0.10],
            hidden: ["dog"]
        ),
        presentLabels: previewLabels
    )
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .frame(width: 280)
    .preferredColorScheme(.light)
}

#Preview("Per-class · mixed · dark") {
    PerClassControls(
        modelSelection: previewSelection(
            global: 0.30,
            overrides: ["sports ball": 0.65, "car": 0.10],
            hidden: ["dog"]
        ),
        presentLabels: previewLabels
    )
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .frame(width: 280)
    .preferredColorScheme(.dark)
}

#Preview("Per-class · all global") {
    PerClassControls(
        modelSelection: previewSelection(global: 0.45),
        presentLabels: previewLabels
    )
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .frame(width: 280)
}

#Preview("Per-class · empty (agnostic / no detections)") {
    PerClassControls(
        modelSelection: previewSelection(),
        presentLabels: []
    )
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .frame(width: 280)
}

/// One row in isolation — the override + reset affordance up close.
#Preview("Per-class row · overridden") {
    PerClassRow(
        modelSelection: previewSelection(overrides: ["sports ball": 0.65]),
        label: "sports ball"
    )
    .padding()
    .frame(width: 280)
}
#endif
