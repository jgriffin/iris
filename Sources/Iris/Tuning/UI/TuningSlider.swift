import SwiftUI

// MARK: - TuningSlider

/// Labeled `Slider` primitive for a continuous `Float` knob — the
/// most common shape on a `DetectorSettings` type (confidence
/// thresholds, aspect ratio bounds, size cutoffs, angle tolerances).
///
/// **Why a thin primitive.** The composed
/// `VisionRectanglesTuningView` re-uses this shape five times in a
/// row; a single primitive keeps the per-knob composition site
/// declarative. Consumers building their own tuning UIs over the
/// schema export can either use this primitive directly or roll
/// their own — there's no compile-time dependency on the schema.
///
/// **Binding-only API.** This view does not touch `TuningModel`.
/// Bindings flow in from the caller, which is responsible for
/// constructing them through `TuningModel.binding(_:)` so writes
/// route through the tier classifier. Keeping the primitive
/// binding-shaped (not model-shaped) means SwiftUI `#Preview`
/// blocks can drive it from a plain `@State Float` without
/// constructing a full tuning model.
///
/// **Style.** Uses the platform's semantic system colors and
/// fonts. The current value renders next to the label in
/// `.monospacedDigit()` so the number doesn't dance as digits roll.
/// Range + step come from the caller (typically pulled off the
/// settings type's `SettingSchema.Knob` for the bound keyPath).
@MainActor
public struct TuningSlider: View {

    public let label: String
    @Binding public var value: Float
    public let range: ClosedRange<Float>
    public let step: Float?
    public let format: FloatingPointFormatStyle<Float>

    /// Build a labeled float slider.
    ///
    /// - Parameters:
    ///   - label: Human-readable knob name.
    ///   - value: Two-way binding to the float value. Typically
    ///     constructed via `TuningModel.binding(_:)` so writes route
    ///     through the tier classifier.
    ///   - range: Inclusive value range — matches the
    ///     `SettingKind.float(range:step:default:)` payload on the
    ///     settings type's schema.
    ///   - step: Optional snap resolution; passes through to SwiftUI's
    ///     `Slider(value:in:step:)`. `nil` leaves the slider
    ///     continuous.
    ///   - format: Number format for the current-value readout. Defaults
    ///     to two-fraction-digit `.number` — appropriate for `0.0...1.0`
    ///     confidence / aspect-ratio knobs; callers with `0...45`-degree
    ///     ranges may want `.number.precision(.fractionLength(0))`.
    public init(
        label: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        step: Float? = nil,
        format: FloatingPointFormatStyle<Float>? = nil
    ) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.format = format ?? .number.precision(.fractionLength(2))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.callout)
                Spacer()
                Text(value, format: format)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            slider
        }
    }

    @ViewBuilder
    private var slider: some View {
        if let step {
            Slider(value: $value, in: range, step: step)
        } else {
            Slider(value: $value, in: range)
        }
    }
}

// MARK: - Preview

#if DEBUG

private struct TuningSliderPreviewHost: View {
    @State var value: Float
    let label: String
    let range: ClosedRange<Float>
    let step: Float?
    var format: FloatingPointFormatStyle<Float>?

    var body: some View {
        TuningSlider(
            label: label,
            value: $value,
            range: range,
            step: step,
            format: format
        )
        .frame(width: 320)
        .padding()
    }
}

#Preview("TuningSlider · confidence (0...1)") {
    TuningSliderPreviewHost(
        value: 0.3,
        label: "Minimum confidence",
        range: 0...1,
        step: 0.01
    )
}

#Preview("TuningSlider · quadrature (0...10, step 0.5)") {
    TuningSliderPreviewHost(
        value: 5.0,
        label: "Quadrature tolerance",
        range: 0...10,
        step: 0.5,
        format: .number.precision(.fractionLength(1))
    )
}

#Preview("TuningSlider · extremes side-by-side") {
    VStack(spacing: 8) {
        TuningSliderPreviewHost(
            value: 0.0,
            label: "Minimum (low)",
            range: 0...1,
            step: 0.01
        )
        TuningSliderPreviewHost(
            value: 1.0,
            label: "Minimum (high)",
            range: 0...1,
            step: 0.01
        )
    }
}

#endif
