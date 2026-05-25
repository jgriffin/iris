import SwiftUI

// MARK: - VisionRectanglesTuningView

/// Built-in tuning surface for `VisionRectanglesDetector`.
///
/// **M5 Wave 2: a thin wrapper over the generic `CapabilityTuningView`.**
/// It used to hand-author one `TuningSlider` per knob. Now it just
/// parameterizes the capability-derived view on the rectangles detector —
/// the controls (aspect / size / quadrature / max-observations) and the
/// *absence* of a confidence control are derived from
/// `VisionRectanglesDetector.capabilities` (geometry quad+box, confidence
/// `.none`), not spelled out here. This is the payoff of the capability
/// model: the rectangles UI is now proof the derivation works, not a
/// parallel hand-maintained list.
///
/// The public `init(model:)` is preserved so existing call sites (the iOS
/// `.sheet` and macOS `.inspector` demo hosts) need no change.
@MainActor
public struct VisionRectanglesTuningView: View {

    @Bindable public var model: TuningModel<VisionRectanglesDetector>

    public init(model: TuningModel<VisionRectanglesDetector>) {
        self.model = model
    }

    public var body: some View {
        CapabilityTuningView(model: model)
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
