import Iris
import SwiftUI

/// The per-class **Display** controls inside the redesigned inspector tuning
/// panel (mock Variant 3). For each label in the working set it renders one
/// dense, value-only `PerClassRow`: a plain tri-state visibility icon + the
/// class name + a right-aligned confidence-floor value. A thin inline slider
/// appears on a row ONLY while that row is being tuned (tapped) or is already
/// overridden — default rows stay value-only so the list reads dense.
///
/// **Store-sourced roster (M12·P3).** The working set is the active detector's
/// **accumulated** labels — the keys of its ``DetectorLabelStore`` slice
/// (`labelStore.labels(for:)`), stable across frames so the rows no longer
/// flicker as detections come and go. `presentLabels` keeps one job: marking
/// which rows are **currently live** (drawn this frame) vs. merely accumulated —
/// the present/absent visual distinction inherited from M11, just re-sourced.
///
/// **Tri-state (redesign).** Each label is Hide / Auto / Show:
/// - **Hide** — never drawn (`OverlayFilter.hiddenLabels`).
/// - **Auto** — drawn when present; the default for a newly-seen label.
/// - **Show** (pinned) — always listed here + drawn when present, even before
///   it first appears (store `Visibility.show`, app-side UI listing state).
///
/// **Working set.** The rows are the active detector's store keys (seen ∪
/// opined-on), sorted alphabetically — pinned-Show rows fall out of store
/// membership automatically. A **Show all classes** expander reveals the
/// detector's full roster (`availableLabels`) so a class can be set to
/// Show/Hide before it ever appears. When the roster isn't statically reachable
/// (a dynamic / class-agnostic detector → `availableLabels == nil`) the expander
/// is replaced by a small caption noting the full roster is unavailable.
///
/// **Render-side, app-side state.** Floors + hidden/pinned live on the
/// ``DetectorLabelStore`` keyed by the active detector id; observing it re-runs
/// each consuming overlay.
struct PerClassControls: View {
    /// The per-detector per-class store — the source of truth for the roster
    /// (its keys) and every per-class opinion (M12·P3).
    @Bindable var labelStore: DetectorLabelStore

    /// The active detector id the rows + roster are keyed to. Switching it
    /// switches the whole per-class view.
    let detectorID: String

    /// The global render floor — the per-label slider's lower bound + fallback,
    /// and the clamp every per-label floor sits above.
    let globalFloor: Double

    /// Labels currently **live** (drawn this frame) in the active mode. Drives
    /// the present/accumulated visual distinction — NOT the roster anymore.
    let presentLabels: Set<String>

    /// The detector's full class roster, when statically known (COCO-80 for a
    /// stock YOLO box detector), else `nil` — drives the "Show all" expander.
    let availableLabels: [String]?

    @State private var showingAll = false

    /// The label whose inline slider is currently revealed (tapped open). A row
    /// that's already overridden shows its slider regardless; this is the lever
    /// for tuning a *default* row in place without first overriding it.
    @State private var tuningLabel: String?

    /// The always-listed rows: the active detector's accumulated labels (store
    /// keys — seen ∪ opined-on), sorted. Pinned-Show rows are included by
    /// construction since opining creates a key.
    private var workingLabels: [String] {
        labelStore.labels(for: detectorID).sorted()
    }

    /// Roster labels NOT already in the working set — what the "Show all"
    /// expander adds. Empty when there's no static roster.
    private var additionalRosterLabels: [String] {
        guard let roster = availableLabels else { return [] }
        let working = Set(workingLabels)
        return roster.filter { !working.contains($0) }.sorted()
    }

    /// Whether the active detector carries any explicit opinion — gates the
    /// group reset affordance.
    private var hasAnyConfiguration: Bool {
        labelStore.hasAnyOpinion(for: detectorID)
    }

    /// Whether there are bare sightings (all-default entries) to forget — gates
    /// the "Clear seen labels" affordance. Opinions are NOT clearable here.
    private var hasClearableSightings: Bool {
        labelStore.hasClearableSightings(for: detectorID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            ForEach(workingLabels, id: \.self) { label in
                PerClassRow(
                    labelStore: labelStore,
                    detectorID: detectorID,
                    globalFloor: globalFloor,
                    label: label,
                    isLive: presentLabels.contains(label),
                    isTuning: tuningLabel == label,
                    onToggleTuning: { toggleTuning(label) }
                )
            }

            if workingLabels.isEmpty {
                Text("No classes seen yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            rosterSection
        }
        // The controls follow the active detector's slice; the transient view
        // state (an open inline slider, the expanded roster) is positional
        // `@State` and would otherwise survive the switch and apply to the new
        // detector's rows (M12·P4).
        .onChange(of: detectorID) {
            tuningLabel = nil
            showingAll = false
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
                .lineLimit(1)

            Spacer(minLength: 4)

            // Group reset affordance: clears every per-class opinion back to
            // Auto + global floor (sightings survive). Shown only when something
            // is set.
            if hasAnyConfiguration {
                Button {
                    labelStore.clearOpinions(for: detectorID)
                    tuningLabel = nil
                } label: {
                    Label("Reset all", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
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
            HStack(spacing: 6) {
                Text("Full class list unavailable for this detector.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                clearSeenButton
            }
        } else if !additionalRosterLabels.isEmpty {
            DisclosureGroup(isExpanded: $showingAll) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(additionalRosterLabels, id: \.self) { label in
                        PerClassRow(
                            labelStore: labelStore,
                            detectorID: detectorID,
                            globalFloor: globalFloor,
                            label: label,
                            isLive: presentLabels.contains(label),
                            isTuning: tuningLabel == label,
                            onToggleTuning: { toggleTuning(label) }
                        )
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Text("Show all classes")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    clearSeenButton
                }
            }
            .accessibilityLabel("Show all classes")
        } else {
            // Roster known but fully covered by the working set — keep the clear
            // affordance reachable.
            HStack {
                Spacer(minLength: 0)
                clearSeenButton
            }
        }
    }

    /// A modest secondary "Clear seen labels" action — forgets bare sightings
    /// for the active detector (opinions survive), styled like the group's other
    /// secondary actions (Reset all). Disabled when there's nothing to clear.
    @ViewBuilder
    private var clearSeenButton: some View {
        Button {
            labelStore.clearSightings(for: detectorID)
            tuningLabel = nil
        } label: {
            Label("Clear seen", systemImage: "eraser")
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!hasClearableSightings)
        .help("Forget seen labels (kept pins, hides, and floors survive)")
        .accessibilityLabel("Clear seen labels")
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
/// - **Name** — readable (`.body`), dimmed when hidden OR when accumulated but
///   not currently live (the present/accumulated distinction, M12·P3).
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
    @Bindable var labelStore: DetectorLabelStore
    let detectorID: String
    let globalFloor: Double
    let label: String
    /// Whether this label is currently drawn (live) vs. merely accumulated.
    let isLive: Bool
    /// Whether this row's inline slider is currently revealed (tapped open).
    let isTuning: Bool
    /// Toggle the inline slider open/closed for this row.
    let onToggleTuning: () -> Void

    private var visibility: LabelVisibility {
        labelStore.visibility(of: label, for: detectorID)
    }
    private var isHidden: Bool { visibility == .hide }
    private var hasOverride: Bool { labelStore.floor(of: label, for: detectorID) != nil }

    /// Whether the inline slider should render: while actively tuning, OR once
    /// the row is overridden (so an override stays adjustable in place).
    private var showsSlider: Bool { (isTuning || hasOverride) && !isHidden }

    /// Per-label floor, clamped to ≥ the global floor on both read and write.
    private var floor: Binding<Double> {
        Binding(
            get: {
                max(
                    labelStore.floor(of: label, for: detectorID) ?? globalFloor,
                    globalFloor
                )
            },
            set: { labelStore.setPerLabelFloor($0, of: label, for: detectorID, globalFloor: globalFloor) }
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

    /// Accumulated-but-not-live rows read dimmer (tertiary) than live ones, so
    /// the stable working list still shows which classes are on screen now.
    private var nameStyle: HierarchicalShapeStyle {
        if isHidden { return .tertiary }
        return isLive ? .primary : .secondary
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
                labelStore.cycleVisibility(of: label, for: detectorID)
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
                .foregroundStyle(nameStyle)
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
                    labelStore.clearPerLabelFloor(of: label, for: detectorID)
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
        // Exact height (not minHeight): every child is single-line, so pin the
        // row so its height can NEVER depend on the pane width — width→height
        // coupling in split-view panes is the classic AppKit
        // "Update Constraints in Window" layout-loop trigger during divider drags.
        .frame(height: 26)
        .contentShape(Rectangle())
    }
}

#if DEBUG
/// A deterministic `DetectorLabelStore` for previews — its own throwaway suite
/// so each case starts from a known per-class state without touching real
/// defaults. Seeds the given detector slice with sightings + opinions.
@MainActor
private func previewStore(
    detectorID: String = previewDetectorID,
    globalFloor: Double = 0.30,
    seen: Set<String> = [],
    overrides: [String: Double] = [:],
    hidden: Set<String> = [],
    pinned: Set<String> = []
) -> DetectorLabelStore {
    let suite = "iris.preview.perclass.\(UUID().uuidString)"
    let store = DetectorLabelStore(defaults: UserDefaults(suiteName: suite)!)
    store.recordSightings(seen, for: detectorID)
    for label in hidden { store.setVisibility(.hide, of: label, for: detectorID) }
    for label in pinned { store.setVisibility(.show, of: label, for: detectorID) }
    for (label, value) in overrides {
        store.setPerLabelFloor(value, of: label, for: detectorID, globalFloor: globalFloor)
    }
    return store
}

private let previewDetectorID = "coreml.yolo26n"
private let previewRoster: [String] = [
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "dog", "cat",
    "sports ball", "bottle", "chair", "couch",
]

/// A deterministic `ModelSelection` wrapping a seeded store + detector id, for
/// the full-panel preview (`TuningGroups` binds `ModelSelection`).
@MainActor
private func previewSelection(
    detectorID: String = previewDetectorID,
    globalFloor: Double = 0.30,
    seen: Set<String> = [],
    overrides: [String: Double] = [:],
    hidden: Set<String> = [],
    pinned: Set<String> = []
) -> ModelSelection {
    let suite = "iris.preview.perclass.sel.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let store = DetectorLabelStore(defaults: defaults)
    store.recordSightings(seen, for: detectorID)
    for label in hidden { store.setVisibility(.hide, of: label, for: detectorID) }
    for label in pinned { store.setVisibility(.show, of: label, for: detectorID) }
    for (label, value) in overrides {
        store.setPerLabelFloor(value, of: label, for: detectorID, globalFloor: globalFloor)
    }
    let sel = ModelSelection(defaults: defaults, labelStore: store)
    sel.detectorID = detectorID
    sel.minConfidence = globalFloor
    return sel
}

/// Full redesigned panel — accumulated rows + a couple overrides + a hidden + a
/// pinned + the show-all roster — in dark mode (the inspector's real context).
/// `presentLabels` is a SUBSET of the accumulated set, so some rows read live
/// (primary) and others accumulated-but-not-live (secondary).
#Preview("Tuning panel · Variant 3 · dark") {
    ScrollView {
        TuningGroups(
            detectorName: "YOLO26n (Core ML)",
            settingsView: nil,
            modelSelection: previewSelection(
                globalFloor: 0.25,
                seen: ["person", "sports ball", "airplane", "car", "dog"],
                overrides: ["sports ball": 0.45, "airplane": 0.35],
                hidden: ["dog"],
                pinned: ["fire hydrant"]
            ),
            presentLabels: ["person", "car"],
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

// MARK: - Static preview gallery (M12·P4 — the favorite pattern)
//
// Every per-class panel state the store can produce, as ONE stacked gallery
// rendered twice (light + dark previews below), so a visual regression in any
// state shows up in a single canvas without running the demo.

/// One labeled gallery entry: a caption + the panel in a boxed, fixed-width
/// frame so cases align vertically and read as a matrix.
private struct PerClassGalleryCase: View {
    let title: String
    let store: DetectorLabelStore
    var globalFloor: Double = 0.30
    var presentLabels: Set<String> = []
    var availableLabels: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            PerClassControls(
                labelStore: store,
                detectorID: previewDetectorID,
                globalFloor: globalFloor,
                presentLabels: presentLabels,
                availableLabels: availableLabels
            )
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The five spec'd states (label-accumulation.md §P4), top to bottom:
/// accumulated-only · mixed-opinion · cleared (opinions only) · no static
/// roster · empty (fresh detector).
@MainActor @ViewBuilder
private var perClassGallery: some View {
    VStack(alignment: .leading, spacing: 18) {
        // Accumulated only: bare sightings, no opinions, nothing live —
        // every row Auto + secondary (dimmed), "Reset all" absent,
        // "Clear seen" enabled.
        PerClassGalleryCase(
            title: "Accumulated only — seen, no opinions, none live",
            store: previewStore(seen: ["person", "car", "dog", "bottle"]),
            availableLabels: previewRoster
        )

        // Mixed opinions: live + accumulated rows, overrides, a hidden, a
        // pinned-never-seen, the show-all roster.
        PerClassGalleryCase(
            title: "Mixed — live ⊂ seen, overrides, hidden, pinned",
            store: previewStore(
                seen: ["person", "sports ball", "car", "dog"],
                overrides: ["sports ball": 0.65, "car": 0.40],
                hidden: ["dog"],
                pinned: ["bicycle"]
            ),
            presentLabels: ["person", "sports ball"],
            availableLabels: previewRoster
        )

        // Cleared: opinions survive a sightings clear — only pinned / hidden /
        // overridden rows remain; "Clear seen" disabled (nothing bare left).
        PerClassGalleryCase(
            title: "Cleared — opinions only, Clear seen disabled",
            store: previewStore(
                overrides: ["sports ball": 0.65],
                hidden: ["dog"],
                pinned: ["bicycle"]
            ),
            availableLabels: previewRoster
        )

        // No static roster (class-agnostic / dynamic detector): the expander
        // is replaced by the unavailable caption; Clear seen stays reachable.
        PerClassGalleryCase(
            title: "No static roster — caption fallback",
            store: previewStore(seen: ["rect"]),
            globalFloor: 0.45,
            presentLabels: ["rect"]
        )

        // Fresh detector: nothing seen, no roster — just the empty caption.
        PerClassGalleryCase(
            title: "Empty — fresh detector, no sightings",
            store: previewStore()
        )
    }
    .padding(16)
    .frame(width: 320)
}

#Preview("Per-class gallery · light") {
    ScrollView { perClassGallery }
        .preferredColorScheme(.light)
}

#Preview("Per-class gallery · dark") {
    ScrollView { perClassGallery }
        .preferredColorScheme(.dark)
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
