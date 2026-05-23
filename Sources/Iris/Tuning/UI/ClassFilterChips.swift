import SwiftUI

// MARK: - ClassFilterChips

/// Multi-select chip cluster for a `Set<String>` knob — the natural
/// shape for class allow-lists on object detectors.
///
/// **Why a thin primitive.** `SettingKind.multiSelect(options:default:)`
/// covers detector class filters (e.g. "show only `person`, `dog`")
/// and any future enum-shaped knob. A row of chips reads more
/// naturally than a multi-select picker for the typical handful of
/// options. No multi-select knobs exist on
/// `VisionRectanglesSettings` today; the primitive is here for the
/// first detector that ships them.
///
/// **Layout.** SwiftUI's stock `Layout` toolkit does not include a
/// flow layout primitive. Rather than ship a custom one inside Iris
/// for this single use site, the chips render in a single horizontal
/// `HStack` wrapped in a `ScrollView` — readable on narrow inspector
/// panes, and the chip count for the typical detector class list is
/// small. Upgrading to a wrapping flow layout is a backwards-
/// compatible change if a real consumer needs it.
///
/// **Style.** Selected chips use `.borderedProminent`; unselected
/// chips use `.bordered`. Both adopt the accent color, so the
/// cluster respects the app's tint without custom palette work.
@MainActor
public struct ClassFilterChips: View {

    public let allOptions: [String]
    @Binding public var selection: Set<String>

    /// Build a multi-select chip cluster.
    ///
    /// - Parameters:
    ///   - allOptions: Every selectable option — typically the
    ///     `SettingKind.multiSelect(options:default:)` payload from
    ///     the settings type's schema.
    ///   - selection: Two-way binding to the chosen subset. Typically
    ///     constructed via `TuningModel.binding(_:)` so writes
    ///     route through the tier classifier.
    public init(allOptions: [String], selection: Binding<Set<String>>) {
        self.allOptions = allOptions
        self._selection = selection
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(allOptions, id: \.self) { option in
                    chip(for: option)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func chip(for option: String) -> some View {
        let isSelected = selection.contains(option)
        Button {
            if isSelected {
                selection.remove(option)
            } else {
                selection.insert(option)
            }
        } label: {
            Text(option)
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .accentColor : .secondary)
        .controlSize(.small)
    }
}

// MARK: - Preview

#if DEBUG

private struct ClassFilterChipsPreviewHost: View {
    @State var selection: Set<String>
    let options: [String]

    var body: some View {
        ClassFilterChips(allOptions: options, selection: $selection)
            .frame(width: 320)
            .padding()
    }
}

#Preview("ClassFilterChips · partial selection") {
    ClassFilterChipsPreviewHost(
        selection: ["person"],
        options: ["person", "dog", "cat"]
    )
}

#Preview("ClassFilterChips · empty selection") {
    ClassFilterChipsPreviewHost(
        selection: [],
        options: ["person", "dog", "cat"]
    )
}

#Preview("ClassFilterChips · all selected") {
    ClassFilterChipsPreviewHost(
        selection: ["person", "dog", "cat", "bird"],
        options: ["person", "dog", "cat", "bird"]
    )
}

#endif
