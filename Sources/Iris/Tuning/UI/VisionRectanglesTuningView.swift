import SwiftUI

// MARK: - VisionRectanglesTuningView

/// Built-in tuning surface for `VisionRectanglesDetector` — the M4
/// concrete view that composes `TuningSlider` over each knob of the
/// detector's `VisionRectanglesSettings`. iOS demos surface it in a
/// `.sheet`; macOS demos surface it in an `.inspector`.
///
/// **Why this view, not a schema renderer.** The M4 brief calls for
/// "one thin view per known detector + primitives". A
/// schema-driven renderer that walks `VisionRectanglesSettings.schema`
/// and switches on every `SettingKind` would do roughly the same job
/// — at the cost of one more layer of generic plumbing in Iris's
/// public surface for a single conformer. Consumers wanting a
/// generic-schema rendering pattern can roll their own from the
/// schema export; Iris ships the concrete view.
///
/// **Binding routing.** Every primitive is constructed via the
/// model's `binding(_:)` helper. This is load-bearing — writes
/// through `Binding($model.settings.minimumAspectRatio)` would
/// bypass the tier classifier and silently leave the cache stale on
/// `.detector`-tier changes. The helper routes every write through
/// `TuningModel.update(_:to:)`, which runs the classifier and
/// invalidates the cache on `.detector` verdicts.
///
/// **Int / Float adaptation.** `maximumObservations` is an `Int`
/// knob; SwiftUI's `Stepper` binds to `Int` directly, so no
/// adapter is needed. The other knobs are `Float`. The `label`
/// property is intentionally *not* surfaced — the schema omits it
/// and a tuning UI for a cosmetic detector label adds little
/// smoke-test value. There is no confidence slider: Vision
/// rectangles have no probabilistic confidence (M5), so the knob
/// was deleted.
@MainActor
public struct VisionRectanglesTuningView: View {

    /// The tuning model. Marked `@Bindable` so SwiftUI tracks the
    /// `@Observable` channels on `TuningModel.settings`. Mutations
    /// route through `model.binding(_:)` so the tier classifier runs
    /// on every transition.
    @Bindable public var model: TuningModel<VisionRectanglesDetector>

    public init(model: TuningModel<VisionRectanglesDetector>) {
        self.model = model
    }

    public var body: some View {
        Form {
            // No "Confidence" section: Vision rectangles carry no
            // probabilistic confidence (`capabilities.confidence ==
            // .none`), so there is no honest slider to show — the knob
            // M5 deleted. (Wave 2 derives this section's presence/absence
            // from the capability descriptor generically.)
            Section("Geometry") {
                TuningSlider(
                    label: "Minimum aspect ratio",
                    value: model.binding(\.minimumAspectRatio),
                    range: 0...1,
                    step: 0.01
                )
                TuningSlider(
                    label: "Maximum aspect ratio",
                    value: model.binding(\.maximumAspectRatio),
                    range: 0...1,
                    step: 0.01
                )
                TuningSlider(
                    label: "Minimum size",
                    value: model.binding(\.minimumSize),
                    range: 0...1,
                    step: 0.01
                )
                TuningSlider(
                    label: "Quadrature tolerance (°)",
                    value: model.binding(\.quadratureToleranceDegrees),
                    range: 0...45,
                    step: 0.5,
                    format: .number.precision(.fractionLength(1))
                )
            }

            Section("Limits") {
                Stepper(
                    value: model.binding(\.maximumObservations),
                    in: 0...100,
                    step: 1
                ) {
                    HStack {
                        Text("Maximum observations")
                            .font(.callout)
                        Spacer()
                        Text("\(model.settings.maximumObservations)")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG

#Preview("VisionRectanglesTuningView · defaults") {
    VisionRectanglesTuningView(
        model: TuningModel(
            detector: VisionRectanglesDetector(settings: VisionRectanglesSettings())
        )
    )
    .frame(width: 360, height: 480)
}

#Preview("VisionRectanglesTuningView · permissive") {
    VisionRectanglesTuningView(
        model: TuningModel(
            detector: VisionRectanglesDetector(
                settings: VisionRectanglesSettings(
                    minimumAspectRatio: 0.3,
                    maximumAspectRatio: 1.0,
                    minimumSize: 0.05,
                    maximumObservations: 20,
                    quadratureToleranceDegrees: 35.0
                )
            )
        )
    )
    .frame(width: 360, height: 480)
}

#endif
