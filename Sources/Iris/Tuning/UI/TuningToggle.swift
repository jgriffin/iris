import SwiftUI

// MARK: - TuningToggle

/// Labeled `Toggle` primitive for a `Bool` knob.
///
/// **Why a thin primitive.** Same rationale as `TuningSlider` — the
/// settings types tend to share anatomy, so a single primitive per
/// `SettingKind` keeps the composed views declarative. No `Bool`
/// knobs exist on `VisionRectanglesSettings` today; this primitive
/// is here for the first conformer that does (e.g. an NMS-enabled
/// flag, a "what if?" preview mode) and to round out the
/// schema-kind coverage.
///
/// **Binding-only API.** Like `TuningSlider`, this view does not
/// touch `TuningModel`. Bindings flow in from the caller and should
/// be constructed through `TuningModel.binding(_:)` so writes route
/// through the tier classifier.
///
/// **Style.** Uses SwiftUI's stock `Toggle` with a leading label —
/// matches the form-row look of `TuningSlider`. No custom colors.
@MainActor
public struct TuningToggle: View {

    public let label: String
    @Binding public var isOn: Bool

    /// Build a labeled boolean toggle.
    ///
    /// - Parameters:
    ///   - label: Human-readable knob name.
    ///   - isOn: Two-way binding to the boolean value. Typically
    ///     constructed via `TuningModel.binding(_:)` so writes
    ///     route through the tier classifier.
    public init(label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    public var body: some View {
        Toggle(label, isOn: $isOn)
            .font(.callout)
    }
}

// MARK: - Preview

#if DEBUG

private struct TuningTogglePreviewHost: View {
    @State var isOn: Bool
    let label: String

    var body: some View {
        TuningToggle(label: label, isOn: $isOn)
            .frame(width: 320)
            .padding()
    }
}

#Preview("TuningToggle · on") {
    TuningTogglePreviewHost(isOn: true, label: "Suppress overlapping boxes")
}

#Preview("TuningToggle · off") {
    TuningTogglePreviewHost(isOn: false, label: "Show low-confidence detections")
}

#Preview("TuningToggle · stack") {
    VStack(alignment: .leading, spacing: 4) {
        TuningTogglePreviewHost(isOn: true, label: "Apply NMS")
        TuningTogglePreviewHost(isOn: false, label: "Mirror horizontally")
        TuningTogglePreviewHost(isOn: true, label: "Track across frames")
    }
}

#endif
