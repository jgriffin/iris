import Iris
import SwiftUI

/// The per-class **Display** controls inside the redesigned inspector tuning
/// panel (mock Variant 3). For each label in the working set it renders one
/// dense, value-only `PerClassRow`: a plain tri-state visibility icon + the
/// class name + a right-aligned confidence-floor value. A thin inline slider
/// appears on a row ONLY while that row is being tuned (tapped) or is already
/// overridden — default rows stay value-only so the list reads dense.
///
/// **Tri-state (redesign).** Each label is Hide / Auto / Show:
/// - **Hide** — never drawn (`OverlayFilter.hiddenLabels`).
/// - **Auto** — drawn when present; the default for a newly-seen label.
/// - **Show** (pinned) — always listed here + drawn when present, even before
///   it first appears (`ModelSelection.pinnedLabels`, app-side UI state).
///
/// **Working set.** The rows are the union of (present ∪ pinned ∪ configured
/// hidden), sorted alphabetically. A **Show all classes** expander reveals the
/// detector's full roster (`availableLabels`) so a class can be set to
/// Show/Hide before it ever appears. When the roster isn't statically reachable
/// (a dynamic / class-agnostic detector → `availableLabels == nil`) the expander
/// is replaced by a small caption noting the full roster is unavailable.
///
/// **Render-side, app-side state.** Floors + hidden/pinned live on
/// `ModelSelection`; observing it re-runs each consuming overlay.
struct PerClassControls: View {
    @Bindable var modelSelection: ModelSelection

    /// Distinct, non-empty labels currently visible in the active mode.
    let presentLabels: Set<String>

    /// The detector's full class roster, when statically known (COCO-80 for a
    /// stock YOLO box detector), else `nil` — drives the "Show all" expander.
    let availableLabels: [String]?

    @State private var showingAll = false

    /// The label whose inline slider is currently revealed (tapped open). A row
    /// that's already overridden shows its slider regardless; this is the lever
    /// for tuning a *default* row in place without first overriding it.
    @State private var tuningLabel: String?

    /// The always-listed rows: present ∪ pinned ∪ configured-hidden, sorted.
    private var workingLabels: [String] {
        let configuredHidden = modelSelection.hiddenLabels
        let union = presentLabels
            .union(modelSelection.pinnedLabels)
            .union(configuredHidden)
        return union.sorted()
    }

    /// Roster labels NOT already in the working set — what the "Show all"
    /// expander adds. Empty when there's no static roster.
    private var additionalRosterLabels: [String] {
        guard let roster = availableLabels else { return [] }
        let working = Set(workingLabels)
        return roster.filter { !working.contains($0) }.sorted()
    }

    /// Whether any per-class state is set — gates the group reset affordance.
    private var hasAnyConfiguration: Bool {
        !modelSelection.hiddenLabels.isEmpty
            || !modelSelection.pinnedLabels.isEmpty
            || !modelSelection.perLabelMinConfidence.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            ForEach(workingLabels, id: \.self) { label in
                PerClassRow(
                    modelSelection: modelSelection,
                    label: label,
                    isTuning: tuningLabel == label,
                    onToggleTuning: { toggleTuning(label) }
                )
            }

            if workingLabels.isEmpty {
                Text("No classes seen yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            rosterSection
        }
    }

    /// Reveal / hide the inline slider for `label`. Tapping a row's value opens
    /// its slider; tapping again (or another row) collapses it.
    private func toggleTuning(_ label: String) {
        tuningLabel = (tuningLabel == label) ? nil : label
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Text("Per class")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 4)

            // Group reset affordance: clears every per-class override back to
            // Auto + global floor. Shown only when something is set.
            if hasAnyConfiguration {
                Button {
                    modelSelection.hiddenLabels.removeAll()
                    modelSelection.pinnedLabels.removeAll()
                    modelSelection.perLabelMinConfidence.removeAll()
                    tuningLabel = nil
                } label: {
                    Label("Reset all", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reset every class to Auto and the global floor")
                .accessibilityLabel("Reset all classes")
            }
        }
    }

    @ViewBuilder
    private var rosterSection: some View {
        if availableLabels == nil {
            // No static roster for this detector (dynamic / class-agnostic).
            Text("Full class list unavailable for this detector.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else if !additionalRosterLabels.isEmpty {
            DisclosureGroup(isExpanded: $showingAll) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(additionalRosterLabels, id: \.self) { label in
                        PerClassRow(
                            modelSelection: modelSelection,
                            label: label,
                            isTuning: tuningLabel == label,
                            onToggleTuning: { toggleTuning(label) }
                        )
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Show all classes")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityLabel("Show all classes")
        }
    }
}

/// One dense per-class row (mock Variant 3, one line):
///
/// ```
/// [eye]  class name        [slider?]  [↺?]  0.25
/// ```
///
/// - **Eye** — a PLAIN tri-state SF Symbol (no circular container, which would
///   read as a radio button): `eye.slash` (Hide) / `eye` outline (Auto) /
///   `eye.fill` (Show/pinned). Tapping cycles Hide → Auto → Show.
/// - **Name** — readable (`.body`), dimmed when hidden.
/// - **Inline slider** — NOT permanently shown. It appears only while the row is
///   being tuned (`isTuning`, tapped open) or is already overridden, letting a
///   default row stay value-only/dense until you choose to tune it.
/// - **Reset** (`arrow.counterclockwise`) — immediately LEFT of the value, shown
///   ONLY when the row is overridden (its floor differs from the global), so the
///   right-aligned value column stays aligned across default rows.
/// - **Value** — right-aligned, tabular digits, fixed-width column.
///
/// **Floor binding + clamp.** The slider's `get` returns the label's override if
/// present, else the global floor; `set` writes a clamped override (≥ global).
/// The slider's range lower bound is the global floor too. Tapping the value
/// reveals the slider; once it differs from global the row is "overridden" (the
/// reset icon appears); reset clears it back to value-only.
struct PerClassRow: View {
    @Bindable var modelSelection: ModelSelection
    let label: String
    /// Whether this row's inline slider is currently revealed (tapped open).
    let isTuning: Bool
    /// Toggle the inline slider open/closed for this row.
    let onToggleTuning: () -> Void

    private var visibility: ModelSelection.LabelVisibility {
        modelSelection.visibility(of: label)
    }
    private var isHidden: Bool { visibility == .hide }
    private var hasOverride: Bool { modelSelection.perLabelMinConfidence[label] != nil }

    /// Whether the inline slider should render: while actively tuning, OR once
    /// the row is overridden (so an override stays adjustable in place).
    private var showsSlider: Bool { (isTuning || hasOverride) && !isHidden }

    /// Global floor as the per-label slider's lower bound + fallback value.
    private var globalFloor: Double { modelSelection.minConfidence }

    /// Per-label floor, clamped to ≥ the global floor on both read and write.
    private var floor: Binding<Double> {
        Binding(
            get: {
                max(
                    modelSelection.perLabelMinConfidence[label] ?? globalFloor,
                    globalFloor
                )
            },
            set: { modelSelection.setPerLabelFloor($0, for: label) }
        )
    }

    private var eyeIcon: String {
        switch visibility {
        case .hide: return "eye.slash"
        case .auto: return "eye"
        case .show: return "eye.fill"
        }
    }

    private var eyeStyle: AnyShapeStyle {
        switch visibility {
        case .hide: return AnyShapeStyle(.tertiary)
        case .auto: return AnyShapeStyle(.secondary)
        case .show: return AnyShapeStyle(.tint)
        }
    }

    private var accessibilityVisibilityLabel: String {
        switch visibility {
        case .hide: return "\(label): hidden. Activate to set Auto."
        case .auto: return "\(label): auto. Activate to pin (Show)."
        case .show: return "\(label): shown. Activate to hide."
        }
    }

    /// The global floor's range fits inside `0...1`; once the global hits 1.0
    /// the per-label slider has no room, so guard a non-empty range.
    private var floorRange: ClosedRange<Double> {
        let lower = min(globalFloor, 1.0)
        return lower >= 1.0 ? (1.0...1.0) : lower...1.0
    }

    var body: some View {
        HStack(spacing: 8) {
            // Plain tri-state eye — NO circular/background container.
            Button {
                modelSelection.cycleVisibility(of: label)
            } label: {
                Image(systemName: eyeIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(eyeStyle)
                    .frame(width: 17)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityVisibilityLabel)

            Text(label)
                .font(.body)
                .foregroundStyle(isHidden ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            // Inline mini-slider — only while tuning or overridden. Pushes the
            // value left on those rows; default rows keep the value hard-right.
            if showsSlider {
                Slider(value: floor, in: floorRange, step: 0.05)
                    .controlSize(.mini)
                    .frame(width: 72)
                    .disabled(floorRange.lowerBound >= 1.0)
                    .accessibilityLabel("\(label) minimum confidence")
            }

            // Reset — only on overridden rows, immediately left of the value, so
            // the value column stays aligned on default rows.
            if hasOverride {
                Button {
                    modelSelection.perLabelMinConfidence[label] = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Use global floor")
                .accessibilityLabel("Reset \(label) to global floor")
            }

            // The value — right-aligned, fixed-width, tabular so the column
            // stays aligned across rows. Tapping it reveals / hides the slider.
            Button {
                onToggleTuning()
            } label: {
                Text(String(format: "%.2f", floor.wrappedValue))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(hasOverride ? .primary : .secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .disabled(isHidden)
            .accessibilityLabel("\(label) minimum confidence \(String(format: "%.2f", floor.wrappedValue)). Activate to tune.")
        }
        .frame(minHeight: 26)
        .contentShape(Rectangle())
    }
}

#if DEBUG
/// A deterministic `ModelSelection` for previews — its own throwaway suite so
/// each case starts from a known per-class state without touching real defaults.
@MainActor
private func previewSelection(
    global: Double = 0.30,
    overrides: [String: Double] = [:],
    hidden: Set<String> = [],
    pinned: Set<String> = []
) -> ModelSelection {
    let suite = "iris.preview.perclass.\(UUID().uuidString)"
    let sel = ModelSelection(defaults: UserDefaults(suiteName: suite)!)
    sel.minConfidence = global
    sel.perLabelMinConfidence = overrides
    sel.hiddenLabels = hidden
    sel.pinnedLabels = pinned
    return sel
}

private let previewLabels: Set<String> = ["person", "sports ball", "car", "dog"]
private let previewRoster: [String] = [
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "dog", "cat",
    "sports ball", "bottle", "chair", "couch",
]

/// Full redesigned panel — present rows + a couple overrides + a hidden + a
/// pinned + the show-all roster — in dark mode (the inspector's real context).
#Preview("Tuning panel · Variant 3 · dark") {
    ScrollView {
        TuningGroups(
            detectorName: "YOLO26n (Core ML)",
            settingsView: nil,
            modelSelection: previewSelection(
                global: 0.25,
                overrides: ["sports ball": 0.45, "airplane": 0.35],
                hidden: ["dog"],
                pinned: ["fire hydrant"]
            ),
            presentLabels: ["person", "sports ball", "airplane", "car"],
            availableLabels: [
                "person", "bicycle", "car", "motorcycle", "airplane", "bus",
                "train", "truck", "boat", "traffic light", "fire hydrant",
                "stop sign", "dog", "sports ball", "bottle", "apple", "chair",
            ]
        )
        .padding(16)
    }
    .frame(width: 300, height: 640)
    .background(Color(white: 0.11))
    .preferredColorScheme(.dark)
}

/// The favorite-pattern gallery: per-class controls with a mix of
/// hidden / pinned / overridden / auto rows + the show-all roster, light + dark.
#Preview("Per-class · mixed · light") {
    PerClassControls(
        modelSelection: previewSelection(
            global: 0.30,
            overrides: ["sports ball": 0.65, "car": 0.10],
            hidden: ["dog"],
            pinned: ["bicycle"]
        ),
        presentLabels: previewLabels,
        availableLabels: previewRoster
    )
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .frame(width: 300)
    .preferredColorScheme(.light)
}

#Preview("Per-class · mixed · dark") {
    PerClassControls(
        modelSelection: previewSelection(
            global: 0.30,
            overrides: ["sports ball": 0.65, "car": 0.10],
            hidden: ["dog"],
            pinned: ["bicycle"]
        ),
        presentLabels: previewLabels,
        availableLabels: previewRoster
    )
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .frame(width: 300)
    .preferredColorScheme(.dark)
}

#Preview("Per-class · no static roster") {
    PerClassControls(
        modelSelection: previewSelection(global: 0.45),
        presentLabels: previewLabels,
        availableLabels: nil
    )
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .frame(width: 300)
}

#Preview("Per-class · empty (agnostic / no detections)") {
    PerClassControls(
        modelSelection: previewSelection(),
        presentLabels: [],
        availableLabels: nil
    )
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .frame(width: 300)
}

// MARK: - Tri-state icon decision aid (Part 4)
//
// The HIDE and SHOW glyphs are settled (`eye.slash` / `eye.fill`); the AUTO
// glyph is the open question. This preview renders the three states side by
// side across a few AUTO candidates so the user can pick. The SHIPPED default
// for Auto is the outline `eye` (candidate A).

/// One labeled tri-state triplet using a specific Auto glyph.
private struct TriStateCandidate: View {
    let title: String
    let autoIcon: String

    private func cell(_ icon: String, _ caption: String, _ style: AnyShapeStyle) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(style)
                .frame(width: 24, height: 22)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 64)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                cell("eye.slash", "Hide", AnyShapeStyle(.tertiary))
                cell(autoIcon, "Auto", AnyShapeStyle(.secondary))
                cell("eye.fill", "Show", AnyShapeStyle(.tint))
            }
        }
    }
}

#Preview("Tri-state icon candidates") {
    VStack(alignment: .leading, spacing: 18) {
        Text("AUTO glyph candidates — Hide / Auto / Show")
            .font(.headline)
        // (a) outline eye — the SHIPPED default.
        TriStateCandidate(title: "A · eye (outline) — shipped", autoIcon: "eye")
        // (b) eye with a badge-ish dot connotation (closest SF Symbol).
        TriStateCandidate(title: "B · eye.circle", autoIcon: "eye.circle")
        // (c) dashed circle — "conditional / auto" connotation.
        TriStateCandidate(title: "C · circle.dashed", autoIcon: "circle.dashed")
        // (d) small-filled-in-circle — a quiet "auto" dot.
        TriStateCandidate(title: "D · smallcircle.filled.circle", autoIcon: "smallcircle.filled.circle")
        // (e) sparkles — "automatic" connotation used elsewhere in the system.
        TriStateCandidate(title: "E · wand.and.stars (auto)", autoIcon: "wand.and.stars")
    }
    .padding(20)
    .frame(width: 320)
    .preferredColorScheme(.dark)
}
#endif
